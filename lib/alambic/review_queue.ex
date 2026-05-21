defmodule Alambic.ReviewQueue do
  import Ecto.Query

  alias Alambic.Repo
  alias Alambic.ReviewQueue.Entry

  def enqueue(attrs) do
    %Entry{}
    |> Entry.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:confidence, :model_version, :queued_at, :resolved_at]},
      conflict_target: [:item_id, :stage]
    )
  end

  def resolve(item_id, stage) when stage in [:extraction, :cleaning] do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {_, _} =
      Repo.update_all(
        from(e in Entry,
          where: e.item_id == ^item_id and e.stage == ^stage and is_nil(e.resolved_at)
        ),
        set: [resolved_at: now]
      )

    :ok
  end

  def list_pending do
    Repo.all(
      from e in Entry,
        where: is_nil(e.resolved_at),
        order_by: [asc: e.confidence, asc: e.queued_at]
    )
  end
end
