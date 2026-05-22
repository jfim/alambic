defmodule AlambicWeb.EditCleaningLive do
  use AlambicWeb, :live_view

  alias Alambic.{BlobStore, Cham, Cleanings, ReviewQueue}
  alias Alambic.Cleanings.Ranges

  def mount(%{"item_id" => item_id}, _session, socket) do
    case Cham.fetch_cleaning_content(item_id) do
      {:ok, raw} ->
        text = normalize(raw)
        sha = sha256(text)
        latest = Cleanings.latest(item_id)
        history = if latest, do: Cleanings.history(item_id), else: []
        {ranges, drift?} = initial_ranges(latest, sha)

        {:ok,
         assign(socket,
           item_id: item_id,
           text: text,
           text_sha: sha,
           text_length: String.length(text),
           ranges: ranges,
           latest: latest,
           history: history,
           view_revision: nil,
           viewed: nil,
           drift?: drift?,
           error: nil
         )}

      {:error, reason} ->
        {:ok,
         assign(socket,
           item_id: item_id,
           text: nil,
           text_sha: nil,
           text_length: 0,
           ranges: [],
           latest: nil,
           history: [],
           view_revision: nil,
           viewed: nil,
           drift?: false,
           error: inspect(reason)
         )}
    end
  end

  defp initial_ranges(nil, _sha), do: {[], false}

  defp initial_ranges(%{content_sha256: stored, discard_ranges: ranges}, sha) do
    if stored == sha, do: {ranges, false}, else: {[], true}
  end

  def handle_event("add_span", %{"start" => s, "stop" => e}, socket) do
    case clamp_range(to_int(s), to_int(e), socket.assigns.text_length) do
      {:ok, [s, e]} ->
        {:noreply, assign(socket, ranges: Ranges.merge_in(socket.assigns.ranges, [s, e]))}

      :invalid ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_span", %{"index" => idx}, socket) do
    {:noreply, assign(socket, ranges: Ranges.remove(socket.assigns.ranges, to_int(idx)))}
  end

  def handle_event("edit_range", %{"index" => idx, "start" => s, "stop" => e}, socket) do
    case clamp_range(to_int(s), to_int(e), socket.assigns.text_length) do
      {:ok, [s, e]} ->
        {:noreply,
         assign(socket, ranges: Ranges.replace(socket.assigns.ranges, to_int(idx), [s, e]))}

      :invalid ->
        {:noreply, socket}
    end
  end

  def handle_event("save", _params, socket) do
    %{item_id: item_id, text: text, ranges: ranges} = socket.assigns

    case Cleanings.save_revision(item_id, text, ranges) do
      {:ok, _row, status} ->
        :ok = ReviewQueue.resolve(item_id, :cleaning)
        flash = if status == :unchanged, do: "Saved — no changes.", else: "Saved."

        latest = Cleanings.latest(item_id)
        history = Cleanings.history(item_id)

        {:noreply,
         socket
         |> assign(latest: latest, history: history, drift?: false)
         |> put_flash(:info, flash)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("prev_revision", _params, socket) do
    current =
      socket.assigns.view_revision ||
        (socket.assigns.latest && socket.assigns.latest.revision_id) || 0

    prev = Enum.find(Enum.reverse(socket.assigns.history), fn r -> r.revision_id < current end)

    if prev do
      {:ok, text} = BlobStore.get(prev.content_sha256)

      {:noreply,
       assign(socket,
         view_revision: prev.revision_id,
         viewed: %{text: text, ranges: prev.discard_ranges, rev: prev}
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("next_revision", _params, socket) do
    current = socket.assigns.view_revision || 0
    next = Enum.find(socket.assigns.history, fn r -> r.revision_id > current end)

    cond do
      is_nil(next) ->
        {:noreply, socket}

      socket.assigns.latest && next.revision_id == socket.assigns.latest.revision_id ->
        {:noreply, assign(socket, view_revision: nil, viewed: nil)}

      true ->
        {:ok, text} = BlobStore.get(next.content_sha256)

        {:noreply,
         assign(socket,
           view_revision: next.revision_id,
           viewed: %{text: text, ranges: next.discard_ranges, rev: next}
         )}
    end
  end

  def handle_event("return_to_latest", _params, socket) do
    {:noreply, assign(socket, view_revision: nil, viewed: nil)}
  end

  defp clamp_range(s, e, text_length) do
    s = max(0, s)
    e = min(text_length, e)

    if s < e, do: {:ok, [s, e]}, else: :invalid
  end

  defp normalize(text), do: :unicode.characters_to_nfc_binary(text)
  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_binary(n), do: String.to_integer(n)

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl p-4">
      <header class="flex items-center justify-between mb-3">
        <div>
          <h1 class="text-xl font-semibold">Edit cleaning · {@item_id}</h1>
          <%= if @latest && is_nil(@view_revision) && !@drift? do %>
            <p class="text-xs text-zinc-500">
              Latest · rev {@latest.revision_id} · saved {Calendar.strftime(@latest.created_at, "%Y-%m-%d %H:%M")}
            </p>
          <% end %>
        </div>
        <%= if @latest do %>
          <nav class="flex items-center gap-2 text-sm">
            <button
              phx-click="prev_revision"
              class="px-2 py-1 rounded border"
              disabled={not has_prev?(assigns)}
            >
              ◀ Prev
            </button>
            <span class="text-zinc-600">
              <%= if @view_revision do %>
                rev {@view_revision}/{length(@history)}
              <% else %>
                rev {@latest.revision_id}/{length(@history)} · latest
              <% end %>
            </span>
            <button
              phx-click="next_revision"
              class="px-2 py-1 rounded border"
              disabled={not has_next?(assigns)}
            >
              Next ▶
            </button>
          </nav>
        <% end %>
      </header>

      <%= if @error do %>
        <div class="rounded bg-red-50 p-3 text-red-700 text-sm">
          Could not fetch cleaning content: {@error}
        </div>
      <% else %>
        <%= if @drift? and is_nil(@view_revision) do %>
          <div class="rounded bg-amber-50 p-3 text-amber-900 text-sm mb-3">
            Article text has changed since the last saved revision. Earlier revisions available via ◀ Prev.
          </div>
        <% end %>

        <%= if @view_revision do %>
          <div class="rounded bg-zinc-100 p-2 text-zinc-700 text-xs mb-3">
            Viewing rev {@view_revision} of {length(@history)} · created
            {Calendar.strftime(@viewed.rev.created_at, "%Y-%m-%d %H:%M")} ·
            <button phx-click="return_to_latest" class="underline">Latest ▶</button> to edit.
          </div>
        <% end %>

        <div class="grid grid-cols-[minmax(0,1fr)_320px] gap-3">
          <div
            id="article-pane"
            phx-hook="CleaningSelection"
            data-text-length={current_length(assigns)}
            data-read-only={if @view_revision, do: "true", else: "false"}
            data-full-text={current_text(assigns)}
            class="rounded border bg-white p-3 font-mono text-sm whitespace-pre-wrap overflow-auto max-h-[80vh]"
          >{render_article_html(current_text(assigns), current_ranges(assigns))}</div>

          <div class="rounded border bg-white p-3 overflow-auto max-h-[80vh]">
            <h2 class="text-sm font-medium mb-2">Spans ({length(current_ranges(assigns))})</h2>
            <%= if current_ranges(assigns) == [] do %>
              <%= if confirmed_empty?(assigns) do %>
                <p class="text-sm text-emerald-700 bg-emerald-50 rounded p-2">
                  ✓ Confirmed: nothing to discard in this revision.
                </p>
              <% else %>
                <p class="text-sm text-zinc-500">
                  No spans yet. Select text in the article to add one.
                </p>
              <% end %>
            <% end %>
            <ul class="space-y-2">
              <%= for {[s, e], idx} <- Enum.with_index(current_ranges(assigns)) do %>
                <li class="flex flex-col gap-1 text-sm border-b border-zinc-100 pb-2" data-span-idx={idx}>
                  <span
                    class="truncate"
                    title={String.slice(current_text(assigns), s, e - s)}
                  ><%= String.slice(current_text(assigns), s, e - s) %></span>
                  <div class="flex items-center gap-2">
                    <%= if @view_revision do %>
                      <span class="text-zinc-500 text-xs whitespace-nowrap">{s}–{e}</span>
                    <% else %>
                      <form
                        phx-change="edit_range"
                        phx-value-index={idx}
                        class="flex items-center gap-1"
                      >
                        <input
                          type="number"
                          min="0"
                          max={current_length(assigns)}
                          value={s}
                          name="start"
                          class="w-16 border rounded px-1 text-right text-xs"
                        />
                        <span class="text-zinc-400">–</span>
                        <input
                          type="number"
                          min="0"
                          max={current_length(assigns)}
                          value={e}
                          name="stop"
                          class="w-16 border rounded px-1 text-right text-xs"
                        />
                      </form>
                      <button
                        phx-click="delete_span"
                        phx-value-index={idx}
                        title="Delete span"
                        class="ml-auto text-zinc-500 hover:text-rose-600"
                      >
                        🗑
                      </button>
                    <% end %>
                  </div>
                </li>
              <% end %>
            </ul>
          </div>
        </div>

        <div class="flex justify-end mt-3">
          <button
            phx-click="save"
            disabled={not is_nil(@view_revision)}
            title={if @view_revision, do: "Read-only view of a historical revision."}
            class="rounded bg-blue-600 px-3 py-2 text-white text-sm hover:bg-blue-700 disabled:opacity-50"
          >
            Save
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  # Renders the article pane content as safe iodata with NO surrounding
  # whitespace, so the DOM's text content exactly matches the source text.
  # The HEEx template MUST place the call flush against the opening and
  # closing tags of #article-pane — any whitespace there would otherwise be
  # rendered (the pane uses `whitespace-pre-wrap`) and inflate the JS hook's
  # offset count.
  defp render_article_html(text, ranges) do
    text
    |> render_text_with_spans(ranges)
    |> Enum.map(fn
      {:keep, t, _} ->
        Phoenix.HTML.html_escape(t) |> Phoenix.HTML.safe_to_string()

      {:discard, t, idx} ->
        [
          ~s|<span class="bg-rose-200 text-rose-950" data-span-idx="|,
          Integer.to_string(idx),
          ~s|">|,
          Phoenix.HTML.html_escape(t) |> Phoenix.HTML.safe_to_string(),
          ~s|</span>|
        ]
    end)
    |> IO.iodata_to_binary()
    |> Phoenix.HTML.raw()
  end

  # Returns a list of {kind, text, idx} tuples where kind is :keep or :discard.
  # idx is meaningful only for :discard chunks (matches the span index).
  defp render_text_with_spans(nil, _ranges), do: [{:keep, "", 0}]

  defp render_text_with_spans(text, ranges) do
    graphemes = String.graphemes(text)
    sorted = Enum.sort_by(ranges, fn [s, _] -> s end)

    {chunks, cursor, _span_idx} =
      Enum.reduce(sorted, {[], 0, 0}, fn [s, e], {acc, cursor, span_idx} ->
        before_text = graphemes |> Enum.slice(cursor, max(s - cursor, 0)) |> Enum.join()
        discard_text = graphemes |> Enum.slice(s, e - s) |> Enum.join()

        new_acc =
          acc
          |> maybe_append_keep(before_text)
          |> append_discard(discard_text, span_idx)

        {new_acc, e, span_idx + 1}
      end)

    tail = graphemes |> Enum.slice(cursor, length(graphemes) - cursor) |> Enum.join()

    chunks
    |> maybe_append_keep(tail)
    |> Enum.reverse()
  end

  defp maybe_append_keep(acc, ""), do: acc
  defp maybe_append_keep(acc, text), do: [{:keep, text, -1} | acc]

  defp append_discard(acc, text, idx), do: [{:discard, text, idx} | acc]

  defp current_text(%{view_revision: nil, text: text}), do: text
  defp current_text(%{viewed: %{text: text}}), do: text

  defp current_ranges(%{view_revision: nil, ranges: ranges}), do: ranges
  defp current_ranges(%{viewed: %{ranges: ranges}}), do: ranges

  defp current_length(%{view_revision: nil, text_length: n}), do: n
  defp current_length(%{viewed: %{text: text}}), do: String.length(text)

  defp has_prev?(%{view_revision: nil, history: history, latest: latest})
       when length(history) > 1 do
    Enum.any?(history, fn r -> r.revision_id < latest.revision_id end)
  end

  defp has_prev?(%{view_revision: v, history: history}) when not is_nil(v) do
    Enum.any?(history, fn r -> r.revision_id < v end)
  end

  defp has_prev?(_), do: false

  defp has_next?(%{view_revision: nil}), do: false

  defp has_next?(%{view_revision: v, history: history}) do
    Enum.any?(history, fn r -> r.revision_id > v end)
  end

  defp confirmed_empty?(%{
         view_revision: nil,
         drift?: false,
         latest: %{discard_ranges: [], content_sha256: sha},
         text_sha: sha
       }),
       do: true

  defp confirmed_empty?(_), do: false
end
