require 'net/http'
require 'uri'
require 'digest'
require 'erb'
require 'smart_proxy_container_gateway/dependency_injection'
require 'smart_proxy_container_gateway/pulp_connection'
require 'smart_proxy_container_gateway/pulp_redirect_cache'
require 'smart_proxy_container_gateway/profiling'
require 'sequel'
module Proxy
  module ContainerGateway
    extend ::Proxy::Util
    extend ::Proxy::Log

    class ContainerGatewayMain
      attr_reader :database, :client_endpoint

      # Duck-types Net::HTTPResponse (code/body/[]) for cache hits and misses alike.
      ResolvedPulpResponse = Struct.new(:code, :body, :headers) do
        def [](header)
          headers[header.to_s.downcase.to_sym]
        end
      end

      # rubocop:disable Metrics/ParameterLists, Layout/LineLength
      def initialize(database:, pulp_endpoint:, pulp_client_ssl_ca:, pulp_client_ssl_cert:, pulp_client_ssl_key:, client_endpoint: nil,
                     pulp_pool_size: nil, pulp_connect_timeout: nil, pulp_read_timeout: nil, pulp_keep_alive_timeout: nil, cache_url: nil)
        @database = database
        @pulp_endpoint = pulp_endpoint
        @client_endpoint = client_endpoint || pulp_endpoint
        @pulp_client_ssl_ca = pulp_client_ssl_ca
        @pulp_client_ssl_cert = OpenSSL::X509::Certificate.new(File.read(pulp_client_ssl_cert))
        @pulp_client_ssl_key = OpenSSL::PKey::RSA.new(
          File.read(pulp_client_ssl_key)
        )

        pulp_connection_options = { pulp_endpoint: pulp_endpoint, pulp_client_ssl_ca: pulp_client_ssl_ca,
                                    pulp_client_ssl_cert: @pulp_client_ssl_cert, pulp_client_ssl_key: @pulp_client_ssl_key }
        pulp_connection_options[:pool_size] = pulp_pool_size if pulp_pool_size
        pulp_connection_options[:connect_timeout] = pulp_connect_timeout if pulp_connect_timeout
        pulp_connection_options[:read_timeout] = pulp_read_timeout if pulp_read_timeout
        pulp_connection_options[:keep_alive_timeout] = pulp_keep_alive_timeout if pulp_keep_alive_timeout
        @pulp_connection = PulpConnection.new(**pulp_connection_options)
        @redirect_cache = PulpRedirectCache.new(cache_url: cache_url)
        Profiling.instrument_pulp!(self)
      end
      # rubocop:enable Metrics/ParameterLists, Layout/LineLength

      def pulp_registry_request(uri, headers)
        @pulp_connection.request(uri, headers)
      end

      def flatpak_static_index(headers, params = {})
        uri = URI.parse("#{@pulp_endpoint}/pulpcore_registry/index/static")
        unless params.empty?
          uri.query = params.map { |k, v| "#{ERB::Util.url_encode(k.to_s)}=#{ERB::Util.url_encode(v.to_s)}" }.join('&')
        end
        pulp_registry_request(uri, headers)
      end

      def ping(headers)
        uri = URI.parse("#{@pulp_endpoint}/pulpcore_registry/v2/")
        pulp_registry_request(uri, headers)
      end

      def manifests(repository, tag, headers)
        uri = URI.parse(
          "#{@pulp_endpoint}/pulpcore_registry/v2/#{repository}/manifests/#{tag}"
        )
        cached_pulp_request("manifest:#{repository}:#{tag}:#{headers['ACCEPT']}", uri, headers)
      end

      def blobs(repository, digest, headers)
        uri = URI.parse(
          "#{@pulp_endpoint}/pulpcore_registry/v2/#{repository}/blobs/#{digest}"
        )
        cached_pulp_request("blob:#{repository}:#{digest}", uri, headers)
      end

      def tags(repository, headers, params = {})
        query = "?"
        unless params[:n].nil? || params[:n] == ""
          query = "#{query}n=#{params[:n]}"
          query = "#{query}&" unless params[:last].nil?
        end
        query = "#{query}last=#{params[:last]}" unless params[:last].nil? || params[:last] == ""

        uri = URI.parse(
          "#{@pulp_endpoint}/pulpcore_registry/v2/#{repository}/tags/list#{query}"
        )
        cached_pulp_request("tags:#{repository}:#{query}", uri, headers)
      end

      # Manifest resolution is content-negotiated, so the cache key includes Accept;
      # other forwarded headers (Authorization, User-Agent) are excluded since they'd
      # fragment the cache without affecting Pulp's answer.
      def cached_pulp_request(cache_key, uri, headers)
        resolved = @redirect_cache.fetch(cache_key) do
          response = pulp_registry_request(uri, headers)
          { code: response.code, body: response.body,
            headers: { location: response['location'], link: response['link'] }.compact }
        end

        ResolvedPulpResponse.new(resolved[:code], resolved[:body], resolved[:headers])
      end

      def v1_search(params = {})
        if params[:n].nil? || params[:n] == ""
          limit = 25
        else
          limit = params[:n].to_i
        end
        return [] unless limit.positive?

        query = params[:q]
        query = nil if query == ''

        user = params[:user].nil? ? nil : database.connection[:users][{ name: params[:user] }]

        repositories = query ? catalog(user).grep(:name, "%#{query}%") : catalog(user)
        repositories.limit(limit).select_map(::Sequel[:repositories][:name])
      end

      def catalog(user = nil)
        if user.nil?
          unauthenticated_repos
        else
          database.connection[:repositories].
            left_join(:repositories_users, repository_id: :id).
            left_join(:users, ::Sequel[:users][:id] => :user_id).where(user_id: user[:id]).
            or(Sequel[:repositories][:auth_required] => false).order(::Sequel[:repositories][:name])
        end
      end

      def host_catalog(host_uuid = nil)
        if host_uuid.nil?
          unauthenticated_repos
        else
          database.connection[:repositories].
            left_join(:hosts_repositories, repository_id: :id).
            left_join(:hosts, ::Sequel[:hosts][:id] => :host_id).where(uuid: host_uuid).
            or(Sequel[:repositories][:auth_required] => false).order(::Sequel[:repositories][:name])
        end
      end

      def unauthenticated_repos
        database.connection[:repositories].where(auth_required: false).order(:name)
      end

      # Diff-syncs repositories instead of delete-all+reimport, which also avoided
      # cascading deletes onto repositories_users/hosts_repositories for unchanged rows.
      def update_repository_list(repo_list)
        desired = repo_list.each_with_object({}) do |repo, acc|
          acc[repo['repository']] = repo['auth_required'].to_s.downcase == "true"
        end

        repository = database.connection[:repositories]
        database.connection.transaction do
          apply_repository_diff(repository, repository.to_hash(:name, :auth_required), desired)
        end
      end

      def update_user_repo_mapping(user_repo_maps)
        entries = user_repo_maps['users'].flat_map(&:to_a)
        user_ids_by_name = database.connection[:users].where(name: entries.map(&:first)).to_hash(:name, :id)
        repo_ids_by_name = auth_required_repository_ids_by_name(
          entries.flat_map { |_username, repos| extract_auth_required_repo_names(repos) }.uniq
        )

        desired_pairs = entries.flat_map do |username, repos|
          user_id = user_ids_by_name[username]
          next [] unless user_id

          repo_ids_for(repos, repo_ids_by_name).map { |repo_id| [repo_id, user_id] }
        end

        sync_repository_pairs(:repositories_users, :user_id, desired_pairs)
      end

      def update_user_repositories(username, repositories)
        user = database.connection[:users][{ name: username }]
        desired_ids = auth_required_repository_ids(repositories)

        sync_repository_mapping(:repositories_users, :user_id, user[:id], desired_ids)
      end

      def update_host_repo_mapping(host_repo_maps)
        sync_repository_pairs(:hosts_repositories, :host_id, build_host_repository_mapping(host_repo_maps))
      end

      def build_host_repository_mapping(host_repo_maps)
        return [] if host_repo_maps['hosts'].nil?

        entries = host_repo_maps['hosts'].flat_map(&:to_a)
                                         .reject { |host_uuid, _repos| host_uuid.nil? || host_uuid.to_s.strip.empty? }
        host_ids_by_uuid = database.connection[:hosts].where(uuid: entries.map(&:first)).to_hash(:uuid, :id)
        repo_ids_by_name = auth_required_repository_ids_by_name(
          entries.flat_map { |_uuid, repos| extract_auth_required_repo_names(repos || []) }.uniq
        )

        entries.flat_map { |host_uuid, repos| host_repository_pairs(host_uuid, repos, host_ids_by_uuid, repo_ids_by_name) }
      end

      def host_repository_pairs(host_uuid, repos, host_ids_by_uuid, repo_ids_by_name)
        host_id = host_ids_by_uuid[host_uuid]
        return [] unless host_id && repos && !repos.empty?

        repo_ids_for(repos, repo_ids_by_name).map { |repo_id| [repo_id, host_id] }
      end

      def repo_ids_for(repos, repo_ids_by_name)
        extract_auth_required_repo_names(repos).filter_map { |name| repo_ids_by_name[name] }
      end

      def extract_auth_required_repo_names(repos)
        repos
          .select { |repo| repo['auth_required'].to_s.downcase == "true" }
          .map { |repo| repo['repository'] }
      end

      def update_host_repositories(uuid, repositories)
        return if uuid.nil? || uuid.to_s.strip.empty?

        host = find_or_create_host(uuid)
        return unless host

        desired_ids = repositories.nil? ? [] : auth_required_repository_ids(repositories)
        sync_repository_mapping(:hosts_repositories, :host_id, host[:id], desired_ids)
      end

      def find_or_create_host(uuid)
        database.connection[:hosts].insert_conflict(target: :uuid, action: :ignore).insert(uuid: uuid)
        database.connection[:hosts][{ uuid: uuid }]
      end

      # Returns:
      # true if the user is authorized to access the repo, or
      # false if the user is not authorized to access the repo or if it does not exist
      def authorized_for_repo?(repo_name, user_token_is_valid, username = nil)
        repository = database.connection[:repositories][{ name: repo_name }]
        return false if repository.nil?
        return true unless repository[:auth_required]
        return false unless username && user_token_is_valid

        database.connection[:repositories_users]
                .join(:users, id: :user_id)
                .where(repository_id: repository[:id], Sequel[:users][:name] => username)
                .any?
      end

      def cert_authorized_for_repo?(repo_name, uuid)
        repository = database.connection[:repositories][{ name: repo_name }]
        return false if repository.nil?
        return true unless repository[:auth_required]

        database.connection[:hosts_repositories]
                .where(repository_id: repository[:id])
                .join(:hosts, id: :host_id)
                .where(Sequel[:hosts][:uuid] => uuid)
                .any?
      end

      def token_user(token)
        database.connection[:users][{
          id: database.connection[:authentication_tokens].where(token_checksum: checksum(token)).select(:user_id)
        }]
      end

      def valid_token?(token)
        !database.connection[:authentication_tokens].where(token_checksum: checksum(token)).where do
          expire_at > Sequel::CURRENT_TIMESTAMP
        end.empty?
      end

      # Combines valid_token? + token_user into a single query for callers that need
      # both (they're always called together on the request path).
      def valid_token_user(token)
        database.connection[:users]
                .join(:authentication_tokens, user_id: :id)
                .where(Sequel[:authentication_tokens][:token_checksum] => checksum(token))
                .where { Sequel[:authentication_tokens][:expire_at] > Sequel::CURRENT_TIMESTAMP }
                .select_all(:users)
                .first
      end

      def insert_token(username, token, expire_at_string, clear_expired_tokens: true)
        checksum = Digest::SHA256.hexdigest(token)
        user = Sequel::Model(database.connection[:users]).find_or_create(name: username)

        database.connection.transaction(isolation: :serializable, retry_on: [Sequel::SerializationFailure]) do
          database.connection[:authentication_tokens].where(:token_checksum => checksum).delete
          Sequel::Model(database.connection[:authentication_tokens]).
            create(token_checksum: checksum, expire_at: expire_at_string.to_s, user_id: user.id)
          return unless clear_expired_tokens
          return unless due_for_token_cleanup?

          database.connection[:authentication_tokens].where { expire_at < Sequel::CURRENT_TIMESTAMP }.delete
        end
      end

      private

      # Expired tokens are already excluded by valid_token?'s own WHERE clause, so
      # delaying their deletion doesn't affect auth correctness -- only table size.
      # Rate-limits the sweep so it isn't paid on every single login.
      TOKEN_CLEANUP_INTERVAL = 300 # seconds

      def due_for_token_cleanup?
        now = Time.now
        return false if @last_token_cleanup_at && (now - @last_token_cleanup_at) < TOKEN_CLEANUP_INTERVAL

        @last_token_cleanup_at = now
        true
      end

      def checksum(token)
        Digest::SHA256.hexdigest(token)
      end

      def apply_repository_diff(repository, existing, desired)
        to_remove = existing.keys - desired.keys
        to_add = desired.keys - existing.keys
        to_update = desired.keys.select { |name| existing.key?(name) && existing[name] != desired[name] }

        repository.where(name: to_remove).delete unless to_remove.empty?
        repository.import(%i[name auth_required], to_add.map { |name| [name, desired[name]] }) unless to_add.empty?
        to_update.each { |name| repository.where(name: name).update(auth_required: desired[name]) }
      end

      def auth_required_repository_ids(repository_names)
        database.connection[:repositories].where(name: repository_names, auth_required: true).select_map(:id)
      end

      def auth_required_repository_ids_by_name(repository_names)
        database.connection[:repositories].where(name: repository_names, auth_required: true).to_hash(:name, :id)
      end

      # Syncs join_table rows for a single owner_id to match desired_repository_ids.
      def sync_repository_mapping(join_table, owner_column, owner_id, desired_repository_ids)
        sync_repository_pairs(join_table, owner_column, desired_repository_ids.map { |repo_id| [repo_id, owner_id] },
                              scope: { owner_column => owner_id })
      end

      # Syncs join_table's (repository_id, owner_column) pairs to match desired_pairs,
      # touching only rows that changed instead of a full delete + reimport.
      def sync_repository_pairs(join_table, owner_column, desired_pairs, scope: {})
        table = database.connection[join_table]
        existing_pairs = table.where(scope).select_map([:repository_id, owner_column])

        to_remove = existing_pairs - desired_pairs
        to_add = desired_pairs - existing_pairs

        database.connection.transaction do
          to_remove.each { |repo_id, owner_id| table.where(:repository_id => repo_id, owner_column => owner_id).delete }
          table.import([:repository_id, owner_column], to_add) unless to_add.empty?
        end
      end
    end
  end
end
