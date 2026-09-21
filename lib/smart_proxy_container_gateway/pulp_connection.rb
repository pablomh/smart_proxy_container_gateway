require 'etc'
require 'net/http'
require 'openssl'
require 'uri'

module Proxy
  module ContainerGateway
    # Maintains a small pool of persistent, self-healing Net::HTTP
    # connections to a single Pulp endpoint.
    #
    # Registry pulls call Pulp once per container layer (ping, manifest,
    # blob, and tag resolution), so opening a brand-new TCP+TLS connection
    # per request is expensive. This class keeps a fixed number of
    # connections open across calls, round-robins between them so
    # concurrent callers aren't serialized on a single socket, and
    # transparently discards and rebuilds any connection that fails with a
    # transport-level error.
    #
    # This class does not retry failed requests -- it only ensures the
    # *next* call gets a healthy connection.
    class PulpConnection
      TRANSPORT_ERRORS = [
        EOFError,
        Errno::ECONNRESET,
        Errno::EPIPE,
        IOError,
        Net::OpenTimeout,
        Net::ReadTimeout,
        OpenSSL::SSL::SSLError
      ].freeze

      MIN_POOL_SIZE = 4
      DEFAULT_READ_TIMEOUT = 60
      DEFAULT_KEEP_ALIVE_TIMEOUT = 10

      # pulp_client_ssl_cert/pulp_client_ssl_key are expected to already be
      # parsed OpenSSL::X509::Certificate/OpenSSL::PKey::RSA objects (as
      # ContainerGatewayMain already holds them), not file paths.
      # pulp_client_ssl_ca stays a file path, passed straight through to
      # Net::HTTP#ca_file=.
      # rubocop:disable Metrics/ParameterLists
      def initialize(pulp_endpoint:, pulp_client_ssl_ca:, pulp_client_ssl_cert:, pulp_client_ssl_key:,
                     pool_size: default_pool_size, connect_timeout: nil, read_timeout: DEFAULT_READ_TIMEOUT,
                     keep_alive_timeout: DEFAULT_KEEP_ALIVE_TIMEOUT)
        @pulp_uri = URI.parse(pulp_endpoint)
        @pulp_client_ssl_ca = pulp_client_ssl_ca
        @pulp_client_ssl_cert = pulp_client_ssl_cert
        @pulp_client_ssl_key = pulp_client_ssl_key
        @connect_timeout = connect_timeout
        @read_timeout = read_timeout
        @keep_alive_timeout = keep_alive_timeout

        @pool_size = pool_size
        @connections = Array.new(pool_size)
        @connection_mutexes = Array.new(pool_size) { Mutex.new }
        @next_index = 0
        @index_mutex = Mutex.new
      end
      # rubocop:enable Metrics/ParameterLists

      # Sends a GET request for +uri+ with +headers+ over a pooled,
      # persistent connection and returns the raw Net::HTTPResponse.
      def request(uri, headers)
        pooled_connection do |http|
          net_request = Net::HTTP::Get.new(uri)
          headers.each { |key, value| net_request[key] = value }
          http.request(net_request)
        end
      end

      private

      # Unverified starting point, not a derived number -- revisit once real
      # throughput/latency numbers from a loaded capsule are available.
      def default_pool_size
        [Etc.nprocessors, MIN_POOL_SIZE].max
      end

      # Picks a connection slot round-robin, guards it with its own mutex
      # (so different slots can be used concurrently while a given slot
      # serializes callers), lazily starts it, and self-heals on transport
      # errors by discarding the broken connection before re-raising.
      def pooled_connection
        index = next_index
        @connection_mutexes[index].synchronize do
          http = (@connections[index] ||= build_connection)
          http.start unless http.started?
          yield http
        rescue *TRANSPORT_ERRORS
          discard_connection(index)
          raise
        end
      end

      def next_index
        @index_mutex.synchronize do
          index = @next_index
          @next_index = (@next_index + 1) % @pool_size
          index
        end
      end

      def build_connection
        http = Net::HTTP.new(@pulp_uri.host, @pulp_uri.port)
        http.use_ssl = true
        http.ca_file = @pulp_client_ssl_ca
        http.cert = @pulp_client_ssl_cert
        http.key = @pulp_client_ssl_key
        http.open_timeout = @connect_timeout if @connect_timeout
        http.read_timeout = @read_timeout
        http.keep_alive_timeout = @keep_alive_timeout
        http
      end

      def discard_connection(index)
        http = @connections[index]
        @connections[index] = nil
        return unless http

        begin
          http.finish if http.started?
        rescue IOError, SystemCallError
          # Connection was already broken; nothing left to clean up.
        end
      end
    end
  end
end
