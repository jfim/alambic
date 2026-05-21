defmodule Alambic.Models do
  import Ecto.Query

  alias Alambic.Models.Model
  alias Alambic.Repo

  def list, do: Repo.all(from m in Model, order_by: [asc: m.stage, asc: m.version])

  def active_for(stage) when stage in [:extraction, :cleaning] do
    Repo.one(from m in Model, where: m.stage == ^stage and m.status == :active)
  end

  def activate(version) when is_binary(version) do
    case Repo.get(Model, version) do
      nil ->
        {:error, :not_found}

      %Model{stage: stage} = model ->
        Repo.transaction(fn ->
          Repo.update_all(
            from(m in Model, where: m.stage == ^stage and m.status == :active),
            set: [status: :retired]
          )

          {:ok, updated} = model |> Model.changeset(%{status: :active}) |> Repo.update()
          updated
        end)
    end
  end
end
