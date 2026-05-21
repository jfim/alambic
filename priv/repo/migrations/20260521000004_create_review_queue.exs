defmodule Alambic.Repo.Migrations.CreateReviewQueue do
  use Ecto.Migration

  def change do
    create table(:review_queue, primary_key: false) do
      add :item_id, :string, primary_key: true, null: false
      add :stage, :string, primary_key: true, null: false
      add :confidence, :float, null: false
      add :model_version, :string, null: false
      add :queued_at, :utc_datetime, null: false
      add :resolved_at, :utc_datetime
    end

    create index(:review_queue, [:resolved_at, :confidence])
  end
end
