defmodule Longx.Jobs.Log do
  @moduledoc """
  A background job's output within bounds, whatever the job writes for however
  long: the **head** (`head_bytes`, 64 KB — the start-up, the configuration,
  the first error) and a **rolling tail** of two segments (`segment_bytes`,
  1 MB each) that take turns — when the one being written is full, the older
  one is emptied and written next, and what it held is counted as omitted. A
  job writing gigabytes for hours keeps about 2 MB on disk; reading it says
  where the middle went (`[… N bytes (M lines) omitted …]`).

  A line redrawn with `\\r` (a progress bar) keeps its last state; the line
  still being drawn is held in memory (`partial_bytes`, 64 KB, its latest
  part) and shown at the end of a read. Colours are stripped when the model
  reads (`render/2`, `read/2`: `tail:` lines, `grep:` a substring).

  Files in `dir`: `head.log`, `tail-0.log`, `tail-1.log`, and `log.json`
  (the counters and which segment is current) written at each rotation and
  on `close/1`, so a finished job reads back from its directory.
  """

  @head_bytes 64 * 1024
  @segment_bytes 1024 * 1024
  @partial_bytes 64 * 1024

  defstruct [
    :dir,
    :head_dev,
    :seg_devs,
    head_limit: @head_bytes,
    segment_limit: @segment_bytes,
    partial_limit: @partial_bytes,
    head: 0,
    seg: 0,
    sizes: {0, 0},
    seg_lines: {0, 0},
    bytes: 0,
    lines: 0,
    omitted_bytes: 0,
    omitted_lines: 0,
    partial: ""
  ]

  @type t :: %__MODULE__{}

  @doc "A fresh log in `dir` (created, emptied). Options: `head_bytes`, `segment_bytes`, `partial_bytes`."
  @spec open(Path.t(), keyword) :: t
  def open(dir, opts \\ []) do
    File.mkdir_p!(dir)

    %__MODULE__{
      dir: dir,
      head_limit: Keyword.get(opts, :head_bytes, @head_bytes),
      segment_limit: Keyword.get(opts, :segment_bytes, @segment_bytes),
      partial_limit: Keyword.get(opts, :partial_bytes, @partial_bytes),
      head_dev: device(dir, "head.log"),
      seg_devs: {device(dir, "tail-0.log"), device(dir, "tail-1.log")}
    }
  end

  defp device(dir, name) do
    {:ok, dev} = :file.open(Path.join(dir, name), [:raw, :binary, :write])
    dev
  end

  @doc "Takes a chunk of output: complete lines are kept (a `\\r`-redrawn one as its last state), the rest waits."
  @spec write(t, binary) :: t
  def write(%__MODULE__{} = log, data) when is_binary(data) do
    [partial | complete] = (log.partial <> data) |> String.split("\n") |> Enum.reverse()
    log = %{log | bytes: log.bytes + byte_size(data)}

    complete
    |> Enum.reverse()
    |> Enum.reduce(log, &store(&2, collapse(&1) <> "\n"))
    |> Map.put(:partial, cap(collapse_partial(partial), log.partial_limit))
  end

  # a terminal redraws the line at each \r: its last state is what stayed
  defp collapse(line), do: line |> String.trim_trailing("\r") |> last_segment()

  defp collapse_partial(line), do: last_segment(line)

  defp last_segment(line) do
    case String.split(line, "\r") do
      [one] -> one
      parts -> parts |> Enum.reject(&(&1 == "")) |> List.last() || ""
    end
  end

  defp cap(text, limit) when byte_size(text) > limit,
    do: binary_part(text, byte_size(text) - limit, limit)

  defp cap(text, _limit), do: text

  defp store(%__MODULE__{head: head, head_limit: limit} = log, line) when head < limit do
    :ok = :file.write(log.head_dev, line)
    %{log | head: head + byte_size(line), lines: log.lines + 1}
  end

  defp store(%__MODULE__{seg: seg} = log, line) do
    :ok = :file.write(elem(log.seg_devs, seg), line)

    log = %{
      log
      | sizes: put_elem(log.sizes, seg, elem(log.sizes, seg) + byte_size(line)),
        seg_lines: put_elem(log.seg_lines, seg, elem(log.seg_lines, seg) + 1),
        lines: log.lines + 1
    }

    if elem(log.sizes, seg) >= log.segment_limit, do: rotate(log), else: log
  end

  # the full segment stays; the older one is emptied and written next
  defp rotate(%__MODULE__{seg: seg} = log) do
    other = 1 - seg
    :ok = :file.close(elem(log.seg_devs, other))
    dev = device(log.dir, "tail-#{other}.log")

    %{
      log
      | seg: other,
        seg_devs: put_elem(log.seg_devs, other, dev),
        omitted_bytes: log.omitted_bytes + elem(log.sizes, other),
        omitted_lines: log.omitted_lines + elem(log.seg_lines, other),
        sizes: put_elem(log.sizes, other, 0),
        seg_lines: put_elem(log.seg_lines, other, 0)
    }
    |> tap(&save_meta/1)
  end

  @doc "Counters: `bytes` and `lines` the job wrote, what was omitted from the middle."
  @spec stats(t) :: %{
          bytes: integer,
          lines: integer,
          omitted_bytes: integer,
          omitted_lines: integer
        }
  def stats(%__MODULE__{} = log),
    do: Map.take(log, [:bytes, :lines, :omitted_bytes, :omitted_lines])

  @doc "The kept text (see `read/2` for the options)."
  @spec render(t, keyword) :: String.t()
  def render(%__MODULE__{} = log, opts \\ []), do: compose(log.dir, meta(log), opts)

  @doc "Writes the counters and closes the files; the log reads back with `read/2`."
  @spec close(t) :: :ok
  def close(%__MODULE__{} = log) do
    save_meta(log)
    :file.close(log.head_dev)
    :file.close(elem(log.seg_devs, 0))
    :file.close(elem(log.seg_devs, 1))
    :ok
  end

  @doc "A closed log's text: `tail:` the last lines, `grep:` only lines holding it; colours stripped."
  @spec read(Path.t(), keyword) :: String.t()
  def read(dir, opts \\ []), do: compose(dir, load_meta(dir), opts)

  @doc "A closed log's counters."
  @spec read_stats(Path.t()) :: map
  def read_stats(dir) do
    m = load_meta(dir)

    %{
      bytes: m.bytes,
      lines: m.lines,
      omitted_bytes: m.omitted_bytes,
      omitted_lines: m.omitted_lines
    }
  end

  defp meta(log) do
    %{
      seg: log.seg,
      bytes: log.bytes,
      lines: log.lines,
      omitted_bytes: log.omitted_bytes,
      omitted_lines: log.omitted_lines,
      partial: log.partial
    }
  end

  defp save_meta(log),
    do: File.write!(Path.join(log.dir, "log.json"), Jason.encode!(meta(log)))

  defp load_meta(dir) do
    case File.read(Path.join(dir, "log.json")) do
      {:ok, json} ->
        m = Jason.decode!(json)

        %{
          seg: m["seg"],
          bytes: m["bytes"],
          lines: m["lines"],
          omitted_bytes: m["omitted_bytes"],
          omitted_lines: m["omitted_lines"],
          partial: m["partial"] || ""
        }

      {:error, _} ->
        %{seg: 0, bytes: 0, lines: 0, omitted_bytes: 0, omitted_lines: 0, partial: ""}
    end
  end

  defp compose(dir, m, opts) do
    older = file(dir, "tail-#{1 - m.seg}.log")
    current = file(dir, "tail-#{m.seg}.log")

    gap =
      if m.omitted_bytes > 0,
        do: "[… #{m.omitted_bytes} bytes (#{m.omitted_lines} lines) omitted …]\n",
        else: ""

    (file(dir, "head.log") <> gap <> older <> current <> m.partial)
    |> Longx.Agent.Text.utf8()
    |> strip_colours()
    |> select(opts)
  end

  defp file(dir, name) do
    case File.read(Path.join(dir, name)) do
      {:ok, text} -> text
      {:error, _} -> ""
    end
  end

  # CSI sequences (colours, cursor moves) and OSC ones (titles, links)
  defp strip_colours(text),
    do: Regex.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]|\e\][^\a\e]*(\a|\e\\)/, text, "")

  defp select(text, opts) do
    grep = Keyword.get(opts, :grep)
    tail = Keyword.get(opts, :tail)

    if grep in [nil, ""] and tail == nil do
      text
    else
      text
      |> String.split(~r/(?<=\n)/)
      |> Enum.reject(&(&1 == ""))
      |> then(fn lines ->
        if grep in [nil, ""], do: lines, else: Enum.filter(lines, &(&1 =~ grep))
      end)
      |> then(fn lines -> if tail, do: Enum.take(lines, -tail), else: lines end)
      |> Enum.join()
    end
  end
end
