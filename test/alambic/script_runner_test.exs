defmodule Alambic.ScriptRunnerTest do
  use ExUnit.Case, async: true

  alias Alambic.ScriptRunner

  @fixture_path "test/support/fixtures/echo.py"

  test "run_sync/3 returns stdout and exit code for a successful script" do
    assert {:ok, output, 0} =
             ScriptRunner.run_sync("uv", ["run", @fixture_path, "hello"], timeout: 60_000)

    assert %{"echoed" => "hello"} = Jason.decode!(String.trim(output))
  end

  test "run_sync/3 reports timeout when the script exceeds the limit" do
    sleeper = """
    # /// script
    # requires-python = ">=3.11"
    # ///
    import time; time.sleep(5)
    """

    path = Path.join(System.tmp_dir!(), "sleeper_#{System.unique_integer([:positive])}.py")
    File.write!(path, sleeper)
    on_exit(fn -> File.rm(path) end)

    assert {:error, :timeout, _, _} = ScriptRunner.run_sync("uv", ["run", path], timeout: 100)
  end
end
