Sequel.migration do
  up do
    # Looked up once per bearer-token-authenticated request in valid_token?/token_user.
    alter_table(:authentication_tokens) do
      add_index :token_checksum
    end

    # insert_token sweeps expired rows on every insert with no other filter.
    alter_table(:authentication_tokens) do
      add_index :expire_at
    end

    # Looked up via database.connection[:users][{name: ...}] in many request paths.
    alter_table(:users) do
      add_index :name
    end

    # Looked up in authorized_for_repo?, cert_authorized_for_repo?, unauthenticated_repos, and v1_search.
    #
    # NOT made unique: update_repository_list (container_gateway_main.rb) imports repository names
    # straight from the PUT /repository_list request body (container_gateway_api.rb) with no
    # server-side deduplication, so a unique constraint could turn a caller-supplied duplicate into
    # a hard DB error on every sync instead of the current (silently tolerant) behavior.
    alter_table(:repositories) do
      add_index :name
    end

    # hosts_repositories has a composite primary key (host_id, repository_id), which only helps
    # lookups by host_id (or both). cert_authorized_for_repo? filters by repository_id alone.
    alter_table(:hosts_repositories) do
      add_index :repository_id
    end
  end

  down do
    alter_table(:hosts_repositories) do
      drop_index :repository_id
    end

    alter_table(:repositories) do
      drop_index :name
    end

    alter_table(:users) do
      drop_index :name
    end

    alter_table(:authentication_tokens) do
      drop_index :expire_at
    end

    alter_table(:authentication_tokens) do
      drop_index :token_checksum
    end
  end
end
