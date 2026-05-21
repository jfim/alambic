defmodule Alambic.Repo.Migrations.CreateModels do
  use Ecto.Migration

  def change do
    create table(:models, primary_key: false) do
      add :version, :string, primary_key: true
      add :stage, :string, null: false
      add :trained_at, :utc_datetime, null: false
      add :artifact_path, :string, null: false
      add :training_sample_size, :integer, null: false, default: 0
      add :status, :string, null: false
    end

    create index(:models, [:stage])

    create unique_index(:models, [:stage],
             where: "status = 'active'",
             name: :one_active_model_per_stage
           )
  end
end
