defmodule Alambic.Datasets do
  @moduledoc """
  Builds parquet exports of confirmed labels for each stage.
  """

  alias Alambic.{Cleanings, Extractions}
  alias Explorer.DataFrame

  @spec export_parquet(:extraction | :cleaning) :: iodata
  def export_parquet(:extraction) do
    rows = Extractions.list_all()

    df =
      DataFrame.new(%{
        "item_id" => Enum.map(rows, & &1.item_id),
        "content_sha256" => Enum.map(rows, & &1.content_sha256),
        "xpath" => Enum.map(rows, & &1.xpath),
        "confirmed_at" => Enum.map(rows, &DateTime.to_unix(&1.confirmed_at)),
        "updated_at" => Enum.map(rows, &DateTime.to_unix(&1.updated_at)),
        "prior_model_version" => Enum.map(rows, & &1.model_version)
      })

    to_parquet_bytes(df)
  end

  def export_parquet(:cleaning) do
    rows = Cleanings.list_all()

    df =
      DataFrame.new(%{
        "item_id" => Enum.map(rows, & &1.item_id),
        "content_sha256" => Enum.map(rows, & &1.content_sha256),
        "discard_ranges" => Enum.map(rows, & &1.discard_ranges),
        "confirmed_at" => Enum.map(rows, &DateTime.to_unix(&1.confirmed_at)),
        "updated_at" => Enum.map(rows, &DateTime.to_unix(&1.updated_at)),
        "prior_model_version" => Enum.map(rows, & &1.model_version)
      })

    to_parquet_bytes(df)
  end

  defp to_parquet_bytes(df) do
    path =
      Path.join(
        System.tmp_dir!(),
        "alambic_export_#{System.unique_integer([:positive])}.parquet"
      )

    try do
      DataFrame.to_parquet!(df, path, compression: {:zstd, 3})
      File.read!(path)
    after
      File.rm(path)
    end
  end
end
