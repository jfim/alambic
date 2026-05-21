defmodule Alambic.Extractions.Extraction do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:item_id, :string, autogenerate: false}
  schema "extractions" do
    field :xpath, :string
    field :html_snapshot, :string
    field :confirmed_at, :utc_datetime
    field :model_version, :string
  end

  def changeset(extraction, attrs) do
    attrs =
      Map.put_new_lazy(attrs, :confirmed_at, fn ->
        DateTime.utc_now() |> DateTime.truncate(:second)
      end)

    extraction
    |> cast(attrs, [:item_id, :xpath, :html_snapshot, :confirmed_at, :model_version])
    |> validate_required([:item_id, :xpath, :html_snapshot, :confirmed_at])
  end
end
