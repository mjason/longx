defmodule Longx.Agent.Definition.Layout do
  @moduledoc """
  The project's `.longx/` tree: `agent.exs` and `shared/` (agents, plugs,
  knowledge — in git, reviewed) beside `local/` (the same three plus an
  optional `agent.exs` — gitignored: this machine's, this person's, the
  agent's drafts). `ensure_ignored/1` keeps `local/` out of git;
  `promote/2` moves a local file into the shared tree.
  """

  @ignore ".longx/local/"

  @doc "The shared tree's directory for a kind (`:agents` | `:plugs` | `:knowledge`)."
  @spec shared_dir(Path.t(), atom) :: Path.t()
  def shared_dir(root, kind), do: Path.join([root, ".longx/shared", Atom.to_string(kind)])

  @doc "The local tree's directory for a kind."
  @spec local_dir(Path.t(), atom) :: Path.t()
  def local_dir(root, kind), do: Path.join([root, ".longx/local", Atom.to_string(kind)])

  @doc "Adds `.longx/local/` to the project's `.gitignore` once (creates the file when there is none)."
  @spec ensure_ignored(Path.t()) :: :ok | {:error, term}
  def ensure_ignored(root) do
    file = Path.join(root, ".gitignore")

    case File.read(file) do
      {:ok, text} ->
        if Enum.any?(String.split(text, "\n"), &(String.trim(&1) in [@ignore, "/" <> @ignore])),
          do: :ok,
          else: File.write(file, String.trim_trailing(text, "\n") <> "\n" <> @ignore <> "\n")

      {:error, :enoent} ->
        File.write(file, @ignore <> "\n")

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Moves a file of the local tree (`"knowledge/deploy/steps.md"`,
  `"plugs/deploy.exs"`, `"agents/helper/agent.exs"`) into the shared tree,
  replacing what is there. `{:ok, shared_path}`.
  """
  @spec promote(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def promote(root, rel) do
    local = Path.join(root, ".longx/local")
    shared = Path.join(root, ".longx/shared")
    from = Path.expand(rel, local)
    to = Path.expand(rel, shared)

    cond do
      not String.starts_with?(from, local <> "/") ->
        {:error, "#{rel} is not inside the local tree"}

      not File.regular?(from) ->
        {:error, "no local file #{rel}"}

      true ->
        with :ok <- File.mkdir_p(Path.dirname(to)),
             :ok <- File.rename(from, to) do
          {:ok, to}
        else
          {:error, reason} -> {:error, "cannot promote #{rel}: #{:file.format_error(reason)}"}
        end
    end
  end
end
