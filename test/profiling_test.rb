require 'test_helper'
require 'mocha/test_unit'
require 'smart_proxy_container_gateway/profiling'

class ProfilingTest < Test::Unit::TestCase
  def setup
    Proxy::ContainerGateway::Profiling.reset!
  end

  def test_disabled_by_default_does_not_record
    Proxy::ContainerGateway::Profiling.stubs(:enabled?).returns(false)

    Proxy::ContainerGateway::Profiling.record_db(0.5)
    Proxy::ContainerGateway::Profiling.record_pulp(0.5)

    stats = Proxy::ContainerGateway::Profiling.stats
    assert_equal 0, stats[:db_queries]
    assert_equal 0, stats[:pulp_calls]
  end

  def test_records_db_duration_when_enabled
    Proxy::ContainerGateway::Profiling.stubs(:enabled?).returns(true)

    Proxy::ContainerGateway::Profiling.record_db(0.01)
    Proxy::ContainerGateway::Profiling.record_db(0.02)

    stats = Proxy::ContainerGateway::Profiling.stats
    assert_equal 2, stats[:db_queries]
    assert_in_delta 0.03, stats[:db_time], 0.0001
  end

  def test_records_pulp_duration_when_enabled
    Proxy::ContainerGateway::Profiling.stubs(:enabled?).returns(true)

    Proxy::ContainerGateway::Profiling.record_pulp(0.05)

    stats = Proxy::ContainerGateway::Profiling.stats
    assert_equal 1, stats[:pulp_calls]
    assert_in_delta 0.05, stats[:pulp_time], 0.0001
  end

  def test_reset_clears_counters
    Proxy::ContainerGateway::Profiling.stubs(:enabled?).returns(true)
    Proxy::ContainerGateway::Profiling.record_db(0.01)

    Proxy::ContainerGateway::Profiling.reset!

    stats = Proxy::ContainerGateway::Profiling.stats
    assert_equal 0, stats[:db_queries]
    assert_equal 0.0, stats[:db_time]
  end

  def test_log_summary_includes_all_fields
    Proxy::ContainerGateway::Profiling.stubs(:enabled?).returns(true)
    Proxy::ContainerGateway::Profiling.record_db(0.001)
    Proxy::ContainerGateway::Profiling.record_pulp(0.002)

    Proxy::ContainerGateway::Profiling.logger.expects(:info).with do |message|
      message.include?('method=GET') && message.include?('path=/v2/_catalog') &&
        message.include?('status=200') && message.include?('db_queries=1') && message.include?('pulp_calls=1')
    end

    Proxy::ContainerGateway::Profiling.log_summary('GET', '/v2/_catalog', 200, 12.34)
  end

  def test_database_instrumentation_records_and_calls_super
    fake_db_class = Class.new do
      attr_reader :super_called

      def log_duration(duration, sql)
        @super_called = [duration, sql]
      end
    end
    fake_db = fake_db_class.new
    fake_db.extend(Proxy::ContainerGateway::Profiling::DatabaseInstrumentation)
    Proxy::ContainerGateway::Profiling.stubs(:enabled?).returns(true)

    fake_db.log_duration(0.02, 'SELECT 1')

    assert_equal [0.02, 'SELECT 1'], fake_db.super_called
    assert_equal 1, Proxy::ContainerGateway::Profiling.stats[:db_queries]
  end

  def test_pulp_instrumentation_times_and_calls_super
    fake_client_class = Class.new do
      def pulp_registry_request(_uri, _headers)
        sleep 0.01
        'response'
      end
    end
    fake_client = fake_client_class.new
    fake_client.extend(Proxy::ContainerGateway::Profiling::PulpInstrumentation)
    Proxy::ContainerGateway::Profiling.stubs(:enabled?).returns(true)

    result = fake_client.pulp_registry_request('uri', {})

    assert_equal 'response', result
    assert_equal 1, Proxy::ContainerGateway::Profiling.stats[:pulp_calls]
    assert Proxy::ContainerGateway::Profiling.stats[:pulp_time].positive?
  end

  def test_instrument_database_only_extends_when_enabled
    Proxy::ContainerGateway::Profiling.stubs(:enabled?).returns(false)
    fake_connection = fake_sequel_connection

    Proxy::ContainerGateway::Profiling.instrument_database!(fake_connection)

    refute fake_connection.is_a?(Proxy::ContainerGateway::Profiling::DatabaseInstrumentation)
  end

  def test_instrument_database_extends_when_enabled
    Proxy::ContainerGateway::Profiling.stubs(:enabled?).returns(true)
    fake_connection = fake_sequel_connection

    Proxy::ContainerGateway::Profiling.instrument_database!(fake_connection)

    assert fake_connection.is_a?(Proxy::ContainerGateway::Profiling::DatabaseInstrumentation)
    assert_instance_of Proxy::ContainerGateway::Profiling::NullLogger, fake_connection.loggers.first
  end

  def test_middleware_passthrough_when_disabled
    Proxy::ContainerGateway::Profiling.stubs(:enabled?).returns(false)
    app = ->(_env) { [200, {}, ['ok']] }
    middleware = Proxy::ContainerGateway::Profiling::Middleware.new(app)

    Proxy::ContainerGateway::Profiling.expects(:log_summary).never
    result = middleware.call({})

    assert_equal [200, {}, ['ok']], result
  end

  def test_middleware_logs_summary_when_enabled
    Proxy::ContainerGateway::Profiling.stubs(:enabled?).returns(true)
    app = ->(_env) { [200, {}, ['ok']] }
    middleware = Proxy::ContainerGateway::Profiling::Middleware.new(app)

    Proxy::ContainerGateway::Profiling.expects(:log_summary).with('GET', '/foo', 200, instance_of(Float))
    result = middleware.call('REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/foo')

    assert_equal [200, {}, ['ok']], result
  end

  private

  def fake_sequel_connection
    Struct.new(:loggers).new([])
  end
end
