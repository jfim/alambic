defmodule Alambic.HtmlSanitizer do
  @moduledoc """
  Strips dangerous content from HTML before display and rewrites `<img>`
  sources to point at Cham's archived copy of each image.

  Drops scripts, styles, frames, and other interactive/embedded content
  entirely. Removes event-handler attributes (`on*`). For images, drops
  `srcset` and rewrites `src` to the Cham archive URL, mirroring Cham's
  download_images plugin filename scheme: `img_<md5(url)><ext>` where
  `ext` is the lowercased extension from the URL's last path segment
  (kept only when 2–6 chars including the dot). If no usable extension
  is present, the src is dropped.
  """

  @drop_tags ~w(script style iframe object embed noscript link)

  @spec sanitize(binary, String.t()) :: String.t()
  def sanitize(html, item_id) when is_binary(html) and is_binary(item_id) do
    case Floki.parse_document(html) do
      {:ok, tree} -> tree |> walk(item_id) |> Floki.raw_html()
      {:error, _} -> ""
    end
  end

  def sanitize(_, _), do: ""

  defp walk(nodes, item_id) when is_list(nodes),
    do: Enum.flat_map(nodes, &walk_node(&1, item_id))

  defp walk_node({tag, _attrs, _children}, _item_id) when tag in @drop_tags, do: []

  defp walk_node({"img", attrs, children}, item_id) do
    rewritten =
      attrs
      |> Enum.reject(fn {k, _} -> k == "srcset" end)
      |> strip_event_attrs()
      |> rewrite_img_src(item_id)

    [{"img", rewritten, walk(children, item_id)}]
  end

  defp walk_node({tag, attrs, children}, item_id) when is_binary(tag) do
    [{tag, strip_event_attrs(attrs), walk(children, item_id)}]
  end

  defp walk_node(other, _item_id), do: [other]

  defp rewrite_img_src(attrs, item_id) do
    case List.keyfind(attrs, "src", 0) do
      {"src", url} ->
        case cham_asset_url(url, item_id) do
          {:ok, new_url} -> List.keyreplace(attrs, "src", 0, {"src", new_url})
          :error -> List.keydelete(attrs, "src", 0)
        end

      nil ->
        attrs
    end
  end

  defp cham_asset_url(url, item_id) do
    with {:ok, ext} <- extension_for(url) do
      md5 = :crypto.hash(:md5, url) |> Base.encode16(case: :lower)
      base = Application.fetch_env!(:alambic, :cham_base_url)
      {:ok, "#{base}/api/v1/items/#{URI.encode(item_id)}/files/img_#{md5}#{ext}"}
    end
  end

  defp extension_for(url) do
    last_segment = url |> URI.parse() |> Map.get(:path, "") |> Path.basename()

    case String.split(last_segment, ".") do
      [_ | _] = parts when length(parts) >= 2 ->
        ext = "." <> (parts |> List.last() |> String.downcase())

        if String.length(ext) in 2..6 and Regex.match?(~r/^\.[a-z0-9]+$/, ext) do
          {:ok, ext}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp strip_event_attrs(attrs) do
    Enum.reject(attrs, fn {k, _v} -> String.starts_with?(k, "on") end)
  end
end
