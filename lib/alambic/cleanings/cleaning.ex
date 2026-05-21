defmodule Alambic.Cleanings.Cleaning do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:item_id, :string, autogenerate: false}
  schema "cleanings" do
    field :content_sha256, :string
    field :discard_ranges, {:array, {:array, :integer}}, default: []
    field :confirmed_at, :utc_datetime
    field :updated_at, :utc_datetime
    field :model_version, :string
  end

  def changeset(cleaning, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      attrs
      |> Map.put_new(:confirmed_at, now)
      |> Map.put(:updated_at, now)

    cleaning
    |> cast(attrs, [
      :item_id,
      :content_sha256,
      :discard_ranges,
      :confirmed_at,
      :updated_at,
      :model_version
    ])
    |> validate_required([:item_id, :content_sha256, :confirmed_at, :updated_at])
    |> validate_format(:content_sha256, ~r/\A[a-f0-9]{64}\z/)
    |> validate_change(:discard_ranges, &validate_ranges/2)
  end

  defp validate_ranges(:discard_ranges, ranges) do
    if Enum.all?(ranges, &valid_range?/1) do
      []
    else
      [discard_ranges: "must be list of [start, stop] with 0 <= start < stop"]
    end
  end

  defp valid_range?([start, stop])
       when is_integer(start) and is_integer(stop) and start >= 0 and stop > start,
       do: true

  defp valid_range?(_), do: false
end
