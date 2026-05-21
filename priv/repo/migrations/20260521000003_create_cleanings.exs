defmodule Alambic.Repo.Migrations.CreateCleanings do
  use Ecto.Migration

  def change do
    create table(:cleanings, primary_key: false) do
      add :item_id, :string, primary_key: true
      add :content_sha256, :string, null: false, size: 64
      add :discard_ranges, :jsonb, null: false, default: "[]"
      add :confirmed_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
      add :model_version, :string
    end

    create index(:cleanings, [:updated_at])
  end
end
