require 'json'
require 'proxy/log'

module Proxy
  module ContainerGateway
    # Best-effort, shared Valkey cache for Pulp manifest/blob/tag redirect responses.
    #
    # A missing client gem, an unreachable server, or any read/write error never
    # raises -- it just degrades to "caching disabled".
    class PulpRedirectCache
      include ::Proxy::Log

      # Default TTL (seconds) applied to every cached entry.
      #
      # This must stay comfortably shorter than the expiry of the presigned redirect
      # URLs Pulp hands back, or we risk serving a client a redirect location that has
      # already expired on the storage backend. The actual Pulp presigned-URL lifetime
      # isn't known at this layer, so this default is intentionally conservative --
      # tune it if/when that lifetime is confirmed.
      DEFAULT_TTL = 30

      def initialize(cache_url:, ttl: DEFAULT_TTL)
        @cache_url = cache_url
        @ttl = ttl
      end

      # Returns the cached value for +key+ if present; otherwise calls +block+, caches
      # its (JSON-serializable) result, and returns it either way.
      #
      # With no cache_url configured, this is a transparent pass-through: the block
      # always runs and no Valkey client is ever attempted.
      def fetch(key)
        return yield unless enabled?

        cached = read(key)
        return cached unless cached.nil?

        yield.tap { |value| write(key, value) }
      end

      private

      def enabled?
        !@cache_url.to_s.empty?
      end

      def read(key)
        client = cache_client
        return nil unless client

        raw = client.get(key)
        raw.nil? ? nil : JSON.parse(raw, symbolize_names: true)
      rescue StandardError => e
        logger.warn("PulpRedirectCache: failed to read '#{key}' from cache, treating as a cache miss: #{e.message}")
        nil
      end

      def write(key, value)
        client = cache_client
        return unless client

        client.setex(key, @ttl, JSON.generate(value))
      rescue StandardError => e
        logger.warn("PulpRedirectCache: failed to write '#{key}' to cache, skipping: #{e.message}")
      end

      # Lazily connects to Valkey on first use and memoizes the result (including a
      # failed/nil connection) for the lifetime of this object.
      def cache_client
        return @cache_client if defined?(@cache_client)

        @cache_client = connect
      end

      def connect
        require 'redis'
        Redis.new(url: @cache_url)
      rescue LoadError, StandardError => e
        logger.warn("PulpRedirectCache: unable to initialize Valkey client, caching disabled: #{e.message}")
        nil
      end
    end
  end
end
