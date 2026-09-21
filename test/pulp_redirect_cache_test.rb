require 'test_helper'
require 'mocha/test_unit'
require 'json'
require 'smart_proxy_container_gateway/pulp_redirect_cache'

# Hand-rolled stand-in for the 'redis' client gem, so these tests never need a real
# Valkey server (or even the gem itself) to be available.
class FakeCacheClient
  Entry = Struct.new(:value, :ttl)

  attr_reader :store
  attr_writer :raise_on_get, :raise_on_setex

  def initialize
    @store = {}
    @raise_on_get = false
    @raise_on_setex = false
  end

  def get(key)
    raise 'simulated cache GET failure' if @raise_on_get

    entry = @store[key]
    entry&.value
  end

  def setex(key, ttl, value)
    raise 'simulated cache SETEX failure' if @raise_on_setex

    @store[key] = Entry.new(value, ttl)
  end
end

class PulpRedirectCacheTest < Test::Unit::TestCase
  def test_fetch_with_nil_cache_url_always_calls_block
    cache = Proxy::ContainerGateway::PulpRedirectCache.new(cache_url: nil)

    calls = 0
    2.times do
      result = cache.fetch('manifest:repo:tag') do
        calls += 1
        { location: 'http://pulp.example/first' }
      end
      assert_equal({ location: 'http://pulp.example/first' }, result)
    end

    assert_equal 2, calls, 'block should run on every call when caching is disabled'
  end

  def test_fetch_with_blank_cache_url_never_attempts_to_connect
    cache = Proxy::ContainerGateway::PulpRedirectCache.new(cache_url: '')
    cache.expects(:connect).never

    result = cache.fetch('key') { { location: 'http://pulp.example' } }
    assert_equal({ location: 'http://pulp.example' }, result)
  end

  def test_cache_miss_calls_block_and_stores_result_with_ttl
    fake_cache = FakeCacheClient.new
    cache = build_cache(fake_cache, ttl: 45)

    result = cache.fetch('manifest:repo:tag') { { location: 'http://pulp.example/x', code: 200 } }

    assert_equal({ location: 'http://pulp.example/x', code: 200 }, result)
    entry = fake_cache.store['manifest:repo:tag']
    refute_nil entry
    assert_equal JSON.generate(location: 'http://pulp.example/x', code: 200), entry.value
    assert_equal 45, entry.ttl
  end

  def test_cache_hit_returns_stored_value_without_calling_block_again
    fake_cache = FakeCacheClient.new
    cache = build_cache(fake_cache)
    cache.fetch('key') { { location: 'http://pulp.example/first' } }

    calls = 0
    result = cache.fetch('key') do
      calls += 1
      { location: 'http://pulp.example/should-not-be-used' }
    end

    assert_equal({ location: 'http://pulp.example/first' }, result)
    assert_equal 0, calls
  end

  def test_cache_read_error_falls_back_to_calling_block
    fake_cache = FakeCacheClient.new
    fake_cache.raise_on_get = true
    cache = build_cache(fake_cache)

    result = cache.fetch('key') { { location: 'http://pulp.example/fresh' } }
    assert_equal({ location: 'http://pulp.example/fresh' }, result)
  end

  def test_cache_write_error_does_not_raise_and_still_returns_block_result
    fake_cache = FakeCacheClient.new
    fake_cache.raise_on_setex = true
    cache = build_cache(fake_cache)

    result = nil
    assert_nothing_raised do
      result = cache.fetch('key') { { location: 'http://pulp.example/fresh' } }
    end
    assert_equal({ location: 'http://pulp.example/fresh' }, result)
    assert_nil fake_cache.store['key']
  end

  def test_missing_client_gem_disables_caching_without_raising
    cache = Proxy::ContainerGateway::PulpRedirectCache.new(cache_url: 'redis://localhost:6379')
    cache.stubs(:require).with('redis').raises(LoadError, 'cannot load such file -- redis')

    result = cache.fetch('key') { { location: 'http://pulp.example/fresh' } }
    assert_equal({ location: 'http://pulp.example/fresh' }, result)
  end

  def test_cache_connection_failure_disables_caching_without_raising
    cache = Proxy::ContainerGateway::PulpRedirectCache.new(cache_url: 'redis://localhost:6379')
    cache.stubs(:require).with('redis').returns(true)
    unreachable_cache_class = mock('Redis')
    unreachable_cache_class.stubs(:new).raises(StandardError, 'connection refused')
    stub_const('Redis', unreachable_cache_class) do
      result = cache.fetch('key') { { location: 'http://pulp.example/fresh' } }
      assert_equal({ location: 'http://pulp.example/fresh' }, result)
    end
  end

  private

  def build_cache(fake_cache, ttl: 30, cache_url: 'redis://localhost:6379')
    cache = Proxy::ContainerGateway::PulpRedirectCache.new(cache_url: cache_url, ttl: ttl)
    cache.stubs(:connect).returns(fake_cache)
    cache
  end

  # Temporarily defines (or replaces) a top-level constant for the duration of the
  # block, restoring the previous state afterwards. Used to simulate the 'redis'
  # client gem's Redis class without requiring the real gem to be installed.
  def stub_const(name, value)
    had_previous = Object.const_defined?(name)
    previous = Object.const_get(name) if had_previous
    Object.send(:remove_const, name) if had_previous
    Object.const_set(name, value)
    yield
  ensure
    Object.send(:remove_const, name) if Object.const_defined?(name)
    Object.const_set(name, previous) if had_previous
  end
end
