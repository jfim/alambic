defmodule Alambic.Models.Model do
  use Ecto.Schema
  import Ecto.Changeset

  @stages [:extraction, :cleaning]
  @statuses [:active, :retired, :failed]

  @primary_key {:version, :string, autogenerate: false}
  schema "models" do
    field :stage, Ecto.Enum, values: @stages
    field :trained_at, :utc_datetime
    field :artifact_path, :string
    field :training_sample_size, :integer, default: 0
    field :status, Ecto.Enum, values: @statuses
  end

  def changeset(model, attrs) do
    model
    |> cast(attrs, [:version, :stage, :trained_at, :artifact_path, :training_sample_size, :status])
    |> validate_required([:version, :stage, :trained_at, :artifact_path, :status])
  end

  def stages, do: @stages
end
