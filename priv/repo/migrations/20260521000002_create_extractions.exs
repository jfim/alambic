defmodule Alambic.Repo.Migrations.CreateExtractions do
  use Ecto.Migration

  def change do
    create table(:extractions, primary_key: false) do
      add :item_id, :string, primary_key: true
      add :xpath, :string, null: false
      add :content_sha256, :string, null: false, size: 64
      add :confirmed_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
      add :model_version, :string
    end

    create index(:extractions, [:updated_at])
  end
end
