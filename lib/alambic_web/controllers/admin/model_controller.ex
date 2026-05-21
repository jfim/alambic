defmodule AlambicWeb.Admin.ModelController do
  use AlambicWeb, :controller

  alias Alambic.Models

  def index(conn, _params) do
    render(conn, :index, models: Models.list())
  end

  def activate(conn, %{"version" => version}) do
    case Models.activate(version) do
      {:ok, model} -> render(conn, :show, model: model)
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "model not found"})
    end
  end
end
