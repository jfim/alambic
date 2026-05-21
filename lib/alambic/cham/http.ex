defmodule Alambic.Cham.HTTP do
  @behaviour Alambic.Cham

  @impl Alambic.Cham
  def fetch_html(item_id) do
    fetch_html(item_id,
      base_url: Application.fetch_env!(:alambic, :cham_base_url),
      filename: Application.fetch_env!(:alambic, :cham_raw_html_filename)
    )
  end

  @doc false
  def fetch_html(item_id, opts) do
    base = Keyword.fetch!(opts, :base_url)
    filename = Keyword.fetch!(opts, :filename)
    url = "#{base}/api/v1/items/#{URI.encode(item_id)}/files/#{URI.encode(filename)}"

    case Req.get(url) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
