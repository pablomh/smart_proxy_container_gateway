require 'test_helper'
require 'smart_proxy_container_gateway/database'

class SequelMigrationsTest < Test::Unit::TestCase
  def setup
    # Constructing the Database against a fresh sqlite:// connection runs every
    # migration in lib/smart_proxy_container_gateway/sequel_migrations, including 006.
    @database = Proxy::ContainerGateway::Database.new('sqlite://', 20, 30)
  end

  def test_migration_applies_cleanly_and_reaches_latest_version
    assert_equal 6, @database.connection[:schema_info].first[:version]
  end

  def test_authentication_tokens_token_checksum_is_indexed
    assert_index_on(:authentication_tokens, :token_checksum)
  end

  def test_authentication_tokens_expire_at_is_indexed
    assert_index_on(:authentication_tokens, :expire_at)
  end

  def test_users_name_is_indexed
    assert_index_on(:users, :name)
  end

  def test_repositories_name_is_indexed
    assert_index_on(:repositories, :name)
  end

  def test_hosts_repositories_repository_id_is_indexed
    assert_index_on(:hosts_repositories, :repository_id)
  end

  private

  def assert_index_on(table, column)
    indexes = @database.connection.indexes(table)
    assert indexes.values.any? { |definition| definition[:columns] == [column] },
           "Expected an index on #{table}.#{column}, got: #{indexes.inspect}"
  end
end
