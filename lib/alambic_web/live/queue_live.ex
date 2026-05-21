defmodule AlambicWeb.QueueLive do
  use AlambicWeb, :live_view

  alias Alambic.ReviewQueue

  def mount(_params, _session, socket) do
    {:ok, assign(socket, entries: ReviewQueue.list_pending())}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl p-6">
      <h1 class="text-2xl font-semibold mb-4">Review queue</h1>

      <%= if @entries == [] do %>
        <p class="text-zinc-500">Review queue is empty.</p>
      <% else %>
        <ul class="divide-y divide-zinc-200">
          <li :for={e <- @entries} class="py-2 flex justify-between items-center">
            <div>
              <div class="font-medium">{e.item_id}</div>
              <div class="text-sm text-zinc-500">
                {e.stage} · confidence {Float.round(e.confidence, 3)}
              </div>
            </div>
            <.link
              navigate={correction_path(e)}
              class="text-sm text-blue-600 hover:underline"
            >
              Review →
            </.link>
          </li>
        </ul>
      <% end %>
    </div>
    """
  end

  # TODO Task 13: restore ~p sigils once /edit-extraction/:id and /edit-cleaning/:id routes exist
  defp correction_path(%{stage: :extraction, item_id: id}), do: "/edit-extraction/#{id}"
  defp correction_path(%{stage: :cleaning, item_id: id}), do: "/edit-cleaning/#{id}"
end
