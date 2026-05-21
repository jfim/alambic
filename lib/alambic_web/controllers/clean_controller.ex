defmodule AlambicWeb.CleanController do
  use AlambicWeb, :controller

  alias Alambic.Inference

  def create(conn, %{"item_id" => item_id, "text" => text})
      when is_binary(item_id) and is_binary(text) do
    case Inference.clean(item_id, text) do
      {:ok, response} ->
        render(conn, :show, response: response)

      {:error, :no_model} ->
        conn |> put_status(503) |> json(%{error: "no model available"})

      {:error, _reason} ->
        conn |> put_status(500) |> json(%{error: "inference failed"})
    end
  end

  def create(conn, _) do
    conn |> put_status(422) |> json(%{error: "missing required fields: item_id, text"})
  end
end
