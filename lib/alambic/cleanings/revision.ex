defmodule Alambic.Cleanings.Revision do
  use Ecto.Schema
  import Ecto.Changeset

  @sources ~w(human model llm_batch)

  @primary_key false
  schema "cleaning_revisions" do
    field :item_id, :string, primary_key: true
    field :revision_id, :integer, primary_key: true
    field :content_sha256, :string
    field :discard_ranges, {:array, {:array, :integer}}, default: []
    field :created_at, :utc_datetime
    field :model_version, :string
    field :source, :string
  end

  def sources, do: @sources

  def changeset(revision, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    attrs = Map.put_new(attrs, :created_at, now)

    revision
    |> cast(attrs, [
      :item_id,
      :revision_id,
      :content_sha256,
      :discard_ranges,
      :created_at,
      :model_version,
      :source
    ])
    |> validate_required([:item_id, :revision_id, :content_sha256, :created_at, :source])
    |> validate_inclusion(:source, @sources)
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
