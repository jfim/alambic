defmodule Alambic.Cleanings do
  alias Alambic.Cleanings.Cleaning
  alias Alambic.Repo

  def get(item_id), do: Repo.get(Cleaning, item_id)

  def save(attrs) do
    item_id = Map.get(attrs, :item_id) || Map.get(attrs, "item_id")
    existing = item_id && Repo.get(Cleaning, item_id)

    (existing || %Cleaning{})
    |> Cleaning.changeset(attrs)
    |> Repo.insert_or_update()
  end
end
