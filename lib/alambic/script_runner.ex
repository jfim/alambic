defmodule Alambic.ScriptRunner do
  @moduledoc """
  Spawns external commands via Port and collects stdout (with stderr merged in).
  Mirrors the cham-v2 ScriptRunner so future scripts share a convention.
  """

  def run_sync(command, args, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    executable = System.find_executable(command) || raise "executable not found: #{command}"

    port =
      Port.open(
        {:spawn_executable, executable},
        [:binary, :exit_status, :stderr_to_stdout, args: args]
      )

    case collect_output(port, timeout, []) do
      {:ok, output, exit_code} ->
        {:ok, output, exit_code}

      {:error, :timeout, output} ->
        kill_port(port)
        {:error, :timeout, output, ""}
    end
  end

  defp collect_output(port, timeout, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, timeout, [data | acc])

      {^port, {:exit_status, exit_code}} ->
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, output, exit_code}
    after
      timeout ->
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:error, :timeout, output}
    end
  end

  defp kill_port(port) do
    try do
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      Port.close(port)
      System.cmd("kill", ["-9", "#{os_pid}"])
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end
end
