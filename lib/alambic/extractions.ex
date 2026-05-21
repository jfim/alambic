defmodule Alambic.Extractions do
  alias Alambic.Extractions.Extraction
  alias Alambic.Repo

  def get(item_id), do: Repo.get(Extraction, item_id)

  def save(attrs) do
    case Repo.get(Extraction, attrs.item_id) do
      nil -> %Extraction{}
      existing -> existing
    end
    |> Extraction.changeset(attrs)
    |> Repo.insert_or_update()
  end
end
