defmodule Longx.Jobs.LogTest do
  # A background job's output kept within bounds: the head (the start-up, the
  # first error) and a rolling tail, whatever the job writes for however long.
  use ExUnit.Case, async: true

  alias Longx.Jobs.Log

  setup do
    dir = Path.join(System.tmp_dir!(), "longx-joblog-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp lines(from, to), do: Enum.map_join(from..to, "", &"line #{&1}\n")

  test "a small output is kept whole and read back as it was", %{dir: dir} do
    log = Log.open(dir) |> Log.write("hello\nworld\n")
    assert Log.render(log) == "hello\nworld\n"
    assert %{bytes: 12, lines: 2, omitted_bytes: 0} = Log.stats(log)
  end

  test "past the bounds the middle goes: the head stays, the tail rolls, the gap is said",
       %{dir: dir} do
    log =
      Log.open(dir, head_bytes: 64, segment_bytes: 100)
      |> Log.write(lines(1, 200))

    text = Log.render(log)
    # the head: the first lines, whole
    assert String.starts_with?(text, "line 1\nline 2\n")
    # the tail: the last lines
    assert String.ends_with?(text, "line 199\nline 200\n")
    assert text =~ ~r/\[… \d+ bytes \(\d+ lines\) omitted …\]/
    %{omitted_bytes: omitted, omitted_lines: omitted_lines} = Log.stats(log)
    assert omitted > 0 and omitted_lines > 0
    # never more on disk than the head and two segments (a line may run past its bound)
    on_disk = dir |> File.ls!() |> Enum.map(&File.stat!(Path.join(dir, &1)).size) |> Enum.sum()
    assert on_disk < 64 + 2 * 100 + 64
  end

  test "a progress bar redrawn with \\r keeps its last state", %{dir: dir} do
    log = Log.open(dir) |> Log.write("start\n 10%\r 50%\r100%\ndone\r\n")
    assert Log.render(log) == "start\n100%\ndone\n"
  end

  test "a line still being drawn shows its latest state, and a line that never ends is capped",
       %{dir: dir} do
    log = Log.open(dir, partial_bytes: 32) |> Log.write("a\nprogress 1\rprogress 2")
    assert Log.render(log) == "a\nprogress 2"

    long = Log.write(log, String.duplicate("x", 1_000))
    assert byte_size(Log.render(long)) < 100
  end

  test "reading for the model: the last lines, a filter, colours stripped", %{dir: dir} do
    log = Log.open(dir) |> Log.write("\e[32mok\e[0m one\nERROR two\nok three\nERROR four\n")
    assert Log.render(log, tail: 2) == "ok three\nERROR four\n"
    assert Log.render(log, grep: "ERROR") == "ERROR two\nERROR four\n"
    assert Log.render(log, tail: 1, grep: "ok") == "ok three\n"
    assert Log.render(log) =~ "ok one"
    refute Log.render(log) =~ "\e["
  end

  test "a closed log is read back from its directory", %{dir: dir} do
    Log.open(dir, head_bytes: 64, segment_bytes: 100) |> Log.write(lines(1, 200)) |> Log.close()
    text = Log.read(dir, tail: 2)
    assert text == "line 199\nline 200\n"
    assert %{lines: 200} = Log.read_stats(dir)
  end
end
