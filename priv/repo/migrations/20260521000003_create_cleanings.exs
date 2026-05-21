defmodule Alambic.Repo.Migrations.CreateCleanings do
  use Ecto.Migration

  def change do
    create table(:cleanings, primary_key: false) do
      add :item_id, :string, primary_key: true
      add :token_labels, :jsonb, null: false
      add :source_text, :text, null: false
      add :confirmed_at, :utc_datetime, null: false
      add :model_version, :string
    end
  end
end
