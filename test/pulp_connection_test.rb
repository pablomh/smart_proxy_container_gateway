require 'test_helper'
require 'webmock/test_unit'
require 'etc'
require 'smart_proxy_container_gateway/pulp_connection'

class PulpConnectionTest < Test::Unit::TestCase
  PULP_ENDPOINT = 'https://test.example.com'.freeze

  def setup
    @pulp_client_ssl_ca = "#{__dir__}/fixtures/mock_pulp_ca.pem"
    @pulp_client_ssl_cert = OpenSSL::X509::Certificate.new(File.read("#{__dir__}/fixtures/mock_pulp_client.crt"))
    @pulp_client_ssl_key = OpenSSL::PKey::RSA.new(File.read("#{__dir__}/fixtures/mock_pulp_client.key"))
  end

  def build_connection(**opts)
    ::Proxy::ContainerGateway::PulpConnection.new(
      pulp_endpoint: PULP_ENDPOINT,
      pulp_client_ssl_ca: @pulp_client_ssl_ca,
      pulp_client_ssl_cert: @pulp_client_ssl_cert,
      pulp_client_ssl_key: @pulp_client_ssl_key,
      **opts
    )
  end

  def connections_of(pulp_connection)
    pulp_connection.instance_variable_get(:@connections)
  end

  def test_request_returns_response_from_pulp
    stub_request(:get, "#{PULP_ENDPOINT}/pulpcore_registry/v2/").
      to_return(:status => 200, :body => '{"ok":true}')

    pulp_connection = build_connection
    response = pulp_connection.request(URI.parse("#{PULP_ENDPOINT}/pulpcore_registry/v2/"), {})

    assert_equal('200', response.code)
    assert_equal('{"ok":true}', response.body)
  end

  def test_successive_requests_reuse_the_same_connection
    stub_request(:get, "#{PULP_ENDPOINT}/pulpcore_registry/v2/").
      to_return(:status => 200, :body => '{}')

    pulp_connection = build_connection(:pool_size => 1)
    uri = URI.parse("#{PULP_ENDPOINT}/pulpcore_registry/v2/")

    pulp_connection.request(uri, {})
    first_connection = connections_of(pulp_connection)[0]
    assert_not_nil first_connection

    pulp_connection.request(uri, {})
    second_connection = connections_of(pulp_connection)[0]

    assert_same first_connection, second_connection
  end

  def test_pool_round_robins_across_connections
    stub_request(:get, "#{PULP_ENDPOINT}/pulpcore_registry/v2/").
      to_return(:status => 200, :body => '{}')

    pulp_connection = build_connection(:pool_size => 2)
    uri = URI.parse("#{PULP_ENDPOINT}/pulpcore_registry/v2/")

    pulp_connection.request(uri, {})
    first_slot_connection = connections_of(pulp_connection)[0]
    assert_not_nil first_slot_connection
    assert_nil connections_of(pulp_connection)[1]

    pulp_connection.request(uri, {})
    second_slot_connection = connections_of(pulp_connection)[1]
    assert_not_nil second_slot_connection
    refute_same first_slot_connection, second_slot_connection

    # Third call wraps back around to the first slot and reuses it.
    pulp_connection.request(uri, {})
    assert_same first_slot_connection, connections_of(pulp_connection)[0]
  end

  def test_transport_error_discards_connection_and_next_call_gets_a_fresh_one
    uri = URI.parse("#{PULP_ENDPOINT}/pulpcore_registry/v2/")
    stub_request(:get, "#{PULP_ENDPOINT}/pulpcore_registry/v2/").
      to_raise(EOFError).then.
      to_return(:status => 200, :body => '{}')

    pulp_connection = build_connection(:pool_size => 1)

    assert_raise(EOFError) { pulp_connection.request(uri, {}) }
    assert_nil connections_of(pulp_connection)[0], "broken connection should have been discarded"

    response = pulp_connection.request(uri, {})
    assert_equal('200', response.code)
    assert_not_nil connections_of(pulp_connection)[0], "a fresh connection should have been created"
  end

  def test_default_pool_size_scales_with_available_cores
    pulp_connection = build_connection

    expected = [Etc.nprocessors, 4].max
    assert_equal expected, pulp_connection.instance_variable_get(:@pool_size)
  end

  def test_configurable_timeouts_are_applied_to_the_underlying_connection
    stub_request(:get, "#{PULP_ENDPOINT}/pulpcore_registry/v2/").
      to_return(:status => 200, :body => '{}')

    pulp_connection = build_connection(:connect_timeout => 5, :read_timeout => 30, :keep_alive_timeout => 15)
    pulp_connection.request(URI.parse("#{PULP_ENDPOINT}/pulpcore_registry/v2/"), {})

    http = connections_of(pulp_connection)[0]
    assert_equal(5, http.open_timeout)
    assert_equal(30, http.read_timeout)
    assert_equal(15, http.keep_alive_timeout)
  end

  def test_default_connect_timeout_is_left_untouched
    stub_request(:get, "#{PULP_ENDPOINT}/pulpcore_registry/v2/").
      to_return(:status => 200, :body => '{}')

    pulp_connection = build_connection
    pulp_connection.request(URI.parse("#{PULP_ENDPOINT}/pulpcore_registry/v2/"), {})

    http = connections_of(pulp_connection)[0]
    assert_equal(Net::HTTP.new('example.com', 443).open_timeout, http.open_timeout)
    assert_equal(60, http.read_timeout)
    assert_equal(10, http.keep_alive_timeout)
  end
end
