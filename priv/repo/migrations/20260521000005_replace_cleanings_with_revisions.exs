defmodule Alambic.Repo.Migrations.ReplaceCleaningsWithRevisions do
  use Ecto.Migration

  def change do
    drop table(:cleanings)

    create table(:cleaning_revisions, primary_key: false) do
      add :item_id, :string, null: false
      add :revision_id, :bigint, null: false
      add :content_sha256, :string, size: 64, null: false
      add :discard_ranges, :jsonb, null: false, default: "[]"
      add :created_at, :utc_datetime, null: false
      add :model_version, :string
    end

    create unique_index(:cleaning_revisions, [:item_id, :revision_id])
    create index(:cleaning_revisions, [:item_id, :created_at])
  end
end
