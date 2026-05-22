defmodule AlambicWeb.EditExtractionLive do
  use AlambicWeb, :live_view

  alias Alambic.{Cham, Extractions, HtmlSanitizer, ReviewQueue}

  @placeholder_xpath "/html/body"

  def mount(%{"item_id" => item_id}, _session, socket) do
    case Cham.fetch_extraction_html(item_id) do
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
      Extractions.save_with_html(
        %{item_id: socket.assigns.item_id, xpath: @placeholder_xpath},
        socket.assigns.raw_html || ""
      )

    :ok = ReviewQueue.resolve(socket.assigns.item_id, :extraction)
    {:noreply, put_flash(socket, :info, "Extraction confirmed.")}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl p-6">
      <h1 class="text-2xl font-semibold mb-2">Edit extraction · {@item_id}</h1>
      <p class="text-sm text-zinc-500 mb-4">
        Placeholder UI: the real DOM picker will render the page in a sandboxed iframe.
      </p>

      <%= if @error do %>
        <div class="rounded bg-red-50 p-3 text-red-700 text-sm">
          Could not fetch HTML: {@error}
        </div>
      <% else %>
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
