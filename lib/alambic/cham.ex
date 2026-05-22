defmodule Alambic.Cham do
  @moduledoc "Read-only client for the Cham archive API."

  @callback fetch_extraction_html(item_id :: String.t()) :: {:ok, binary} | {:error, term}
  @callback fetch_cleaning_content(item_id :: String.t()) :: {:ok, binary} | {:error, term}

  def fetch_extraction_html(item_id), do: impl().fetch_extraction_html(item_id)
  def fetch_cleaning_content(item_id), do: impl().fetch_cleaning_content(item_id)

  defp impl, do: Application.fetch_env!(:alambic, :cham_impl)
end
