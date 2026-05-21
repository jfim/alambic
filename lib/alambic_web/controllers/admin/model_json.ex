defmodule AlambicWeb.Admin.ModelJSON do
  alias Alambic.Models.Model

  def index(%{models: models}), do: Enum.map(models, &row/1)
  def show(%{model: model}), do: row(model)

  defp row(%Model{} = m) do
    %{
      version: m.version,
      stage: m.stage,
      status: m.status,
      trained_at: m.trained_at,
      artifact_path: m.artifact_path,
      training_sample_size: m.training_sample_size
    }
  end
end
