defmodule Longx.Exec.Policy do
  @moduledoc """
  What a command (or a file operation) may touch, from the sandbox intent
  codex sends with every `process/start` and `fs/*` request — its
  `FileSystemSandboxContext`: a permission profile (`managed` with a
  filesystem policy and a network switch, `disabled` for full access,
  `external` when something else sandboxes) plus the cwd and workspace roots
  the special entries are resolved against.

  This is the one reading of that intent: `Longx.Exec.Sandbox` turns a
  policy into bwrap / seatbelt arguments, `Longx.Exec.Fs` asks `allowed?/3`
  before touching a file (apply_patch writes through the exec-server, so the
  file API is a sandbox boundary too). An intent this module cannot read is
  refused — never widened into "open".
  """

  alias Longx.Exec.PathUri

  @enforce_keys [:kind, :network]
  defstruct [:kind, :network, :cwd, workspace_roots: [], entries: []]

  @typedoc """
  `kind`: `:restricted` (sandboxed per `entries`), `:unrestricted` (full
  access), `:external` (another sandbox is in charge — nothing to enforce).
  `entries`: resolved absolute paths with their access, most general first.
  """
  @type t :: %__MODULE__{
          kind: :restricted | :unrestricted | :external,
          network: :restricted | :enabled,
          cwd: Path.t() | nil,
          workspace_roots: [Path.t()],
          entries: [%{path: Path.t(), access: :read | :write | :deny}]
        }

  @typedoc "`tmpdir:` the executor's `$TMPDIR`; `exists?:` how to check a skip-if-missing entry."
  @type opt :: {:tmpdir, Path.t() | nil} | {:exists?, (Path.t() -> boolean)}

  @doc "The policy of a sandbox context (`nil` = codex asked for no sandbox)."
  @spec parse(map | nil, [opt]) :: {:ok, t} | {:error, String.t()}
  def parse(nil, _opts), do: {:ok, %__MODULE__{kind: :unrestricted, network: :enabled}}

  def parse(%{"permissions" => permissions} = context, opts) do
    with {:ok, cwd} <- optional_path(context["cwd"]),
         {:ok, roots} <- paths(context["workspaceRoots"] || []),
         roots = if(roots == [] and cwd, do: [cwd], else: roots),
         {:ok, policy} <- profile(permissions, roots, opts) do
      {:ok, %{policy | cwd: cwd, workspace_roots: roots}}
    end
  end

  def parse(_context, _opts), do: {:error, "sandbox context without permissions"}

  defp profile(%{"type" => "disabled"}, _roots, _opts),
    do: {:ok, %__MODULE__{kind: :unrestricted, network: :enabled}}

  defp profile(%{"type" => "external"} = p, _roots, _opts),
    do:
      with(
        {:ok, network} <- network(p["network"]),
        do: {:ok, %__MODULE__{kind: :external, network: network}}
      )

  defp profile(%{"type" => "managed", "file_system" => fs} = p, roots, opts) do
    with {:ok, network} <- network(p["network"]),
         {:ok, kind} <- kind(fs["type"]),
         {:ok, entries} <- entries(fs["entries"] || [], roots, opts) do
      {:ok, %__MODULE__{kind: kind, network: network, entries: entries}}
    end
  end

  defp profile(p, _roots, _opts),
    do: {:error, "unknown permission profile: #{inspect(p["type"])}"}

  defp network("enabled"), do: {:ok, :enabled}
  defp network("restricted"), do: {:ok, :restricted}
  defp network(other), do: {:error, "unknown network policy: #{inspect(other)}"}

  defp kind("restricted"), do: {:ok, :restricted}
  defp kind("unrestricted"), do: {:ok, :unrestricted}
  defp kind("external-sandbox"), do: {:ok, :external}
  defp kind(other), do: {:error, "unknown filesystem sandbox kind: #{inspect(other)}"}

  defp entries(raw, roots, opts) do
    exists? = Keyword.get(opts, :exists?, &File.exists?/1)

    Enum.reduce_while(raw, {:ok, []}, fn entry, {:ok, acc} ->
      with {:ok, access} <- access(entry["access"]),
           {:ok, paths} <- resolve(entry["path"], roots, opts) do
        paths =
          if entry["missing_path_behavior"] == "skip",
            do: Enum.filter(paths, exists?),
            else: paths

        {:cont, {:ok, acc ++ for(path <- paths, do: %{path: path, access: access})}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp access("read"), do: {:ok, :read}
  defp access("write"), do: {:ok, :write}
  defp access(mode) when mode in ["deny", "none"], do: {:ok, :deny}
  defp access(other), do: {:error, "unknown access mode: #{inspect(other)}"}

  defp resolve(%{"type" => "path", "path" => uri}, _roots, _opts),
    do: with({:ok, path} <- PathUri.to_path(uri), do: {:ok, [path]})

  defp resolve(%{"type" => "glob_pattern", "pattern" => pattern}, _roots, _opts),
    do: {:ok, Path.wildcard(pattern, match_dot: true)}

  defp resolve(%{"type" => "special", "value" => %{"kind" => "root"}}, _roots, _opts),
    do: {:ok, ["/"]}

  defp resolve(%{"type" => "special", "value" => %{"kind" => "minimal"}}, _roots, _opts),
    do: {:ok, []}

  defp resolve(%{"type" => "special", "value" => %{"kind" => "slash_tmp"}}, _roots, _opts),
    do: {:ok, ["/tmp"]}

  defp resolve(%{"type" => "special", "value" => %{"kind" => "tmpdir"}}, _roots, opts) do
    case Keyword.get_lazy(opts, :tmpdir, fn -> System.get_env("TMPDIR") end) do
      "/" <> _ = dir -> {:ok, [Path.expand(dir)]}
      _ -> {:ok, []}
    end
  end

  defp resolve(%{"type" => "special", "value" => %{"kind" => kind} = value}, roots, _opts)
       when kind in ["project_roots", "current_working_directory"] do
    case value["subpath"] do
      nil -> {:ok, roots}
      subpath -> {:ok, Enum.map(roots, &Path.join(&1, subpath))}
    end
  end

  defp resolve(path, _roots, _opts), do: {:error, "unknown filesystem path: #{inspect(path)}"}

  defp optional_path(nil), do: {:ok, nil}
  defp optional_path(uri), do: PathUri.to_path(uri)

  defp paths(uris) do
    Enum.reduce_while(uris, {:ok, []}, fn uri, {:ok, acc} ->
      case PathUri.to_path(uri) do
        {:ok, path} -> {:cont, {:ok, acc ++ [path]}}
        error -> {:halt, error}
      end
    end)
  end

  @doc "Whether commands must run inside a sandbox at all."
  @spec sandboxed?(t) :: boolean
  def sandboxed?(%__MODULE__{kind: :restricted} = policy), do: not full_write?(policy)
  def sandboxed?(_), do: false

  # codex: root writable and no entry narrowing that down
  defp full_write?(%__MODULE__{entries: entries}) do
    Enum.any?(entries, &(&1.path == "/" and &1.access == :write)) and
      not Enum.any?(entries, &(&1.path != "/" and &1.access in [:read, :deny]))
  end

  @doc "The directories a sandboxed command may write (sorted, unique)."
  @spec writable_roots(t) :: [Path.t()]
  def writable_roots(%__MODULE__{entries: entries}),
    do:
      entries
      |> Enum.filter(&(&1.access == :write))
      |> Enum.map(& &1.path)
      |> Enum.uniq()
      |> Enum.sort()

  @doc """
  Read-only pockets strictly inside writable roots (`.git`, `.codex`… —
  sorted). A path that is also a writable root is no pocket: a grant
  arrives as a read entry *and* a write entry for the same path.
  """
  @spec read_only_paths(t) :: [Path.t()]
  def read_only_paths(%__MODULE__{entries: entries} = policy) do
    roots = writable_roots(policy)

    entries
    |> Enum.filter(fn %{path: path, access: access} ->
      access == :read and path not in roots and
        Enum.any?(roots, fn root -> under?(path, root) end)
    end)
    |> Enum.map(& &1.path)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Paths a command must not see at all (sorted)."
  @spec denied_paths(t) :: [Path.t()]
  def denied_paths(%__MODULE__{entries: entries}),
    do:
      entries
      |> Enum.filter(&(&1.access == :deny))
      |> Enum.map(& &1.path)
      |> Enum.uniq()
      |> Enum.sort()

  @doc "Whether `path` may be read or written under the policy: the most specific entry decides."
  @spec allowed?(t, Path.t(), :read | :write) :: boolean
  def allowed?(%__MODULE__{} = policy, path, mode) do
    if sandboxed?(policy) do
      path = Path.expand(path)

      # the most specific entries decide; at one path a deny beats a write beats a read
      case policy.entries
           |> Enum.filter(&under?(path, &1.path))
           |> Enum.group_by(& &1.path)
           |> Enum.max_by(fn {entry_path, _} -> String.length(entry_path) end, fn -> nil end) do
        nil ->
          mode == :read

        {_, at_path} ->
          accesses = Enum.map(at_path, & &1.access)

          cond do
            :deny in accesses -> false
            :write in accesses -> true
            true -> mode == :read
          end
      end
    else
      true
    end
  end

  @doc "Whether `path` is `root` or inside it (a directory boundary, not a string prefix)."
  @spec under?(Path.t(), Path.t()) :: boolean
  def under?(_path, "/"), do: true
  def under?(path, root), do: path == root or String.starts_with?(path, root <> "/")
end
