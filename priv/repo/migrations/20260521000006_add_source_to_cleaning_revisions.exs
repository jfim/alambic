defmodule Alambic.Repo.Migrations.AddSourceToCleaningRevisions do
  use Ecto.Migration

  def change do
    alter table(:cleaning_revisions) do
      add :source, :string
    end

    # Backfill: today only EditCleaningLive writes revisions (model path does
    # not persist), and tests pass model_version only when simulating a model
    # row. Treat any pre-existing row with model_version IS NULL as human;
    # else model.
    execute(
      "UPDATE cleaning_revisions SET source = CASE WHEN model_version IS NULL THEN 'human' ELSE 'model' END",
      "UPDATE cleaning_revisions SET source = NULL"
    )

    alter table(:cleaning_revisions) do
      modify :source, :string, null: false
    end

    create constraint(:cleaning_revisions, :source_must_be_known,
             check: "source IN ('human', 'model', 'llm_batch')"
           )
  end
end
