defmodule Alambic.Extractions.Extraction do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:item_id, :string, autogenerate: false}
  schema "extractions" do
    field :xpath, :string
    field :content_sha256, :string
    field :confirmed_at, :utc_datetime
    field :updated_at, :utc_datetime
    field :model_version, :string
  end

  def changeset(extraction, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      attrs
      |> Map.put_new(:confirmed_at, now)
      |> Map.put(:updated_at, now)

    extraction
    |> cast(attrs, [:item_id, :xpath, :content_sha256, :confirmed_at, :updated_at, :model_version])
    |> validate_required([:item_id, :xpath, :content_sha256, :confirmed_at, :updated_at])
    |> validate_format(:content_sha256, ~r/\A[a-f0-9]{64}\z/)
  end
end
