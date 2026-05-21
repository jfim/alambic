defmodule Alambic.Extractions do
  alias Alambic.Extractions.Extraction
  alias Alambic.Repo

  def get(item_id), do: Repo.get(Extraction, item_id)

  def save(attrs) do
    item_id = Map.get(attrs, :item_id) || Map.get(attrs, "item_id")
    existing = item_id && Repo.get(Extraction, item_id)

    (existing || %Extraction{})
    |> Extraction.changeset(attrs)
    |> Repo.insert_or_update()
  end
end
