# frozen_string_literal: true

Sequel.migration do
  up do
    run "INSERT INTO provider (name) VALUES ('generic') ON CONFLICT DO NOTHING;"
    alter_table(:host_provider) do
      add_column :config, :jsonb, null: true
    end
  end

  down do
    alter_table(:host_provider) do
      drop_column :config
    end
    run "DELETE FROM provider WHERE name = 'generic';"
  end
end
