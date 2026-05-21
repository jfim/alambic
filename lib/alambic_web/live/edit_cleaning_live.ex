defmodule AlambicWeb.EditCleaningLive do
  use AlambicWeb, :live_view

  alias Alambic.{Cham, Cleanings, HtmlSanitizer, ReviewQueue}

  def mount(%{"item_id" => item_id}, _session, socket) do
    case Cham.fetch_html(item_id) do
      {:ok, raw_html} ->
        {:ok,
         assign(socket,
           item_id: item_id,
           raw_html: raw_html,
           safe_html: HtmlSanitizer.sanitize(raw_html, item_id),
           error: nil
         )}

      {:error, reason} ->
        {:ok,
         assign(socket,
           item_id: item_id,
           raw_html: nil,
           safe_html: nil,
           error: inspect(reason)
         )}
    end
  end

  def handle_event("confirm", _params, socket) do
    {:ok, _} =
      Cleanings.save(%{
        item_id: socket.assigns.item_id,
        token_labels: [%{"token" => "placeholder", "label" => "keep"}],
        source_text: "placeholder"
      })

    :ok = ReviewQueue.resolve(socket.assigns.item_id, :cleaning)
    {:noreply, put_flash(socket, :info, "Cleaning confirmed.")}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl p-6">
      <h1 class="text-2xl font-semibold mb-2">Edit cleaning · {@item_id}</h1>
      <p class="text-sm text-zinc-500 mb-4">
        Placeholder UI: Token annotation pane will replace this once real models exist.
      </p>

      <%= if @error do %>
        <div class="rounded bg-red-50 p-3 text-red-700 text-sm">
          Could not fetch HTML: {@error}
        </div>
      <% else %>
        <div class="rounded border bg-white p-3 mb-3">
          <h2 class="text-sm font-medium mb-2">Token annotation (placeholder)</h2>
          <p class="text-xs text-zinc-500">
            Real implementation will tokenize the extracted text and let the user toggle keep/discard.
          </p>
        </div>
        <div class="rounded border bg-white p-3 overflow-auto text-sm">
          {Phoenix.HTML.raw(@safe_html)}
        </div>
      <% end %>

      <button
        phx-click="confirm"
        class="mt-4 rounded bg-blue-600 px-3 py-2 text-white text-sm hover:bg-blue-700"
      >
        Confirm
      </button>
    </div>
    """
  end
end
