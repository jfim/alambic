defmodule Alambic.Cham do
  @moduledoc "Read-only client for the Cham archive API."

  @callback fetch_html(item_id :: String.t()) :: {:ok, binary} | {:error, term}

  def fetch_html(item_id), do: impl().fetch_html(item_id)

  defp impl, do: Application.fetch_env!(:alambic, :cham_impl)
end
