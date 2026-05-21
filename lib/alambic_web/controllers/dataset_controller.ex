defmodule AlambicWeb.DatasetController do
  use AlambicWeb, :controller

  alias Alambic.{BlobStore, Datasets}

  @stages %{"extraction" => :extraction, "cleaning" => :cleaning}

  def rows(conn, %{"stage" => stage}) when is_map_key(@stages, stage) do
    bytes = Datasets.export_parquet(Map.fetch!(@stages, stage))

    conn
    |> put_resp_content_type("application/octet-stream", nil)
    |> put_resp_header("content-disposition", ~s|attachment; filename="rows.parquet"|)
    |> send_resp(200, bytes)
  end

  def rows(conn, _), do: send_resp(conn, 404, "unknown stage")

  def blob(conn, %{"stage" => stage, "sha256" => sha}) when is_map_key(@stages, stage) do
    case BlobStore.get(sha) do
      {:ok, bytes} ->
        conn
        |> put_resp_content_type("application/octet-stream", nil)
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> send_resp(200, bytes)

      :not_found ->
        send_resp(conn, 404, "not found")
    end
  end

  def blob(conn, _), do: send_resp(conn, 404, "unknown stage")
end
