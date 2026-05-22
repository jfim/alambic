defmodule AlambicWeb.AnnotateCleaningController do
  use AlambicWeb, :controller

  alias Alambic.Cleanings

  def next(conn, _params) do
    case Cleanings.next_for_annotation() do
      nil ->
        render(conn, :done)

      %{item_id: item_id} ->
        redirect(conn, to: ~p"/edit-cleaning/#{item_id}?after=annotate")
    end
  end
end
