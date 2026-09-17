defmodule Longx.Agent.Plugs.AgentsMd do
  @moduledoc """
  The project's own instructions: every `AGENTS.md` from the filesystem
  root down to the working directory, outermost first so the nearest one
  has the last word. Each file is capped (`max_bytes:`, 32 KB) with a
  note where it was cut.
  """

  use Longx.Agent.Plug

  @file_name "AGENTS.md"

  @impl true
  def init(opts), do: Keyword.get(opts, :max_bytes, 32 * 1024)

  @impl true
  def call(%Step{cwd: nil} = step, _max), do: step

  def call(%Step{cwd: cwd} = step, max) do
    cwd
    |> Path.expand()
    |> ancestors()
    |> Enum.map(&Path.join(&1, @file_name))
    |> Enum.filter(&File.regular?/1)
    |> Enum.reduce(step, fn path, acc ->
      Step.instructions(acc, "# #{path}\n\n#{read(path, max)}")
    end)
  end

  # the directory and its parents, root first
  defp ancestors(dir) do
    dir
    |> Stream.unfold(fn
      nil -> nil
      d -> {d, if(Path.dirname(d) == d, do: nil, else: Path.dirname(d))}
    end)
    |> Enum.reverse()
  end

  defp read(path, max) do
    text = File.read!(path)

    if byte_size(text) > max,
      do: binary_part(text, 0, max) <> "\n\n[truncated: #{byte_size(text)} bytes in file]",
      else: text
  end
end
