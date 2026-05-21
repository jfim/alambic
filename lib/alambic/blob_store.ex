defmodule Alambic.BlobStore do
  @moduledoc """
  Content-addressed filesystem store. Keys are sha256 hex of raw bytes.
  On disk, blobs are gzip-compressed and named `<sha256>.gz`.
  """

  @spec put(iodata) :: {:ok, String.t()}
  def put(bytes) do
    raw = IO.iodata_to_binary(bytes)
    sha = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    path = path_for(sha)
    File.mkdir_p!(Path.dirname(path))

    unless File.exists?(path) do
      File.write!(path, :zlib.gzip(raw))
    end

    {:ok, sha}
  end

  @spec get(String.t()) :: {:ok, binary} | :not_found
  def get(sha) when is_binary(sha) do
    path = path_for(sha)

    case File.read(path) do
      {:ok, compressed} -> {:ok, :zlib.gunzip(compressed)}
      {:error, :enoent} -> :not_found
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(sha) when is_binary(sha) do
    case File.rm(path_for(sha)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
    end
  end

  defp path_for(sha) do
    Application.fetch_env!(:alambic, :blob_storage_path)
    |> Path.join("#{sha}.gz")
  end
end
