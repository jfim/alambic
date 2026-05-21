defmodule Alambic.ReviewQueue.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  @stages [:extraction, :cleaning]

  @primary_key false
  schema "review_queue" do
    field :item_id, :string, primary_key: true
    field :stage, Ecto.Enum, values: @stages, primary_key: true
    field :confidence, :float
    field :model_version, :string
    field :queued_at, :utc_datetime
    field :resolved_at, :utc_datetime
  end

  def changeset(entry, attrs) do
    attrs =
      Map.put_new_lazy(attrs, :queued_at, fn ->
        DateTime.utc_now() |> DateTime.truncate(:second)
      end)

    entry
    |> cast(attrs, [:item_id, :stage, :confidence, :model_version, :queued_at, :resolved_at])
    |> validate_required([:item_id, :stage, :confidence, :model_version, :queued_at])
  end

  def stages, do: @stages
end
