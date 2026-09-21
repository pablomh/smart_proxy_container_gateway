require 'proxy/log'

module Proxy
  module ContainerGateway
    # Opt-in (ENV['CONTAINER_GATEWAY_PROFILE']) per-request profiling: total
    # latency, DB query count/time, and Pulp call count/time. Hooks two seams
    # that exist identically regardless of the rest of this codebase's
    # implementation -- Sequel::Database#log_duration and
    # ContainerGatewayMain#pulp_registry_request -- so the same instrumentation
    # works on an unmodified upstream checkout as well as this branch.
    module Profiling
      extend ::Proxy::Log

      def self.enabled?
        !ENV['CONTAINER_GATEWAY_PROFILE'].to_s.empty?
      end

      def self.reset!
        Thread.current[:container_gateway_profile] = { db_queries: 0, db_time: 0.0, pulp_calls: 0, pulp_time: 0.0 }
      end

      def self.stats
        Thread.current[:container_gateway_profile] ||= { db_queries: 0, db_time: 0.0, pulp_calls: 0, pulp_time: 0.0 }
      end

      def self.record_db(duration)
        return unless enabled?

        stats[:db_queries] += 1
        stats[:db_time] += duration
      end

      def self.record_pulp(duration)
        return unless enabled?

        stats[:pulp_calls] += 1
        stats[:pulp_time] += duration
      end

      def self.log_summary(method, path, status, total_ms)
        s = stats
        logger.info(
          format('container_gateway_profile method=%s path=%s status=%s total_ms=%.2f ' \
                 'db_queries=%d db_time_ms=%.2f pulp_calls=%d pulp_time_ms=%.2f',
                 method, path, status, total_ms, s[:db_queries], s[:db_time] * 1000, s[:pulp_calls], s[:pulp_time] * 1000)
        )
      end

      # Sequel skips its own logging (and never calls log_duration) unless at
      # least one logger is registered, so a silent one is added here purely to
      # make Sequel reach the log_duration call DatabaseInstrumentation hooks.
      class NullLogger
        def info(*)
        end

        def warn(*)
        end

        def error(*)
        end
      end

      def self.instrument_database!(connection)
        return unless enabled?

        connection.loggers << NullLogger.new
        connection.extend(DatabaseInstrumentation)
      end

      def self.instrument_pulp!(container_gateway_main)
        container_gateway_main.extend(PulpInstrumentation) if enabled?
      end

      module DatabaseInstrumentation
        def log_duration(duration, sql)
          Profiling.record_db(duration)
          super
        end
      end

      module PulpInstrumentation
        def pulp_registry_request(uri, headers)
          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          super
        ensure
          Profiling.record_pulp(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start)
        end
      end

      class Middleware
        def initialize(app)
          @app = app
          @enabled = Profiling.enabled?
        end

        def call(env)
          return @app.call(env) unless @enabled

          Profiling.reset!
          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          status, headers, body = @app.call(env)
          total_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
          Profiling.log_summary(env['REQUEST_METHOD'], env['PATH_INFO'], status, total_ms)
          [status, headers, body]
        end
      end
    end
  end
end
