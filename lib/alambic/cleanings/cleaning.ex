defmodule Alambic.Cleanings.Cleaning do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:item_id, :string, autogenerate: false}
  schema "cleanings" do
    field :token_labels, {:array, :map}
    field :source_text, :string
    field :confirmed_at, :utc_datetime
    field :model_version, :string
  end

  def changeset(cleaning, attrs) do
    attrs =
      Map.put_new_lazy(attrs, :confirmed_at, fn ->
        DateTime.utc_now() |> DateTime.truncate(:second)
      end)

    cleaning
    |> cast(attrs, [:item_id, :token_labels, :source_text, :confirmed_at, :model_version])
    |> validate_required([:item_id, :token_labels, :source_text, :confirmed_at])
  end
end
