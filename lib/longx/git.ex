defmodule Longx.Git do
  @moduledoc """
  Repository operations, all performed by the bundled git
  (`Longx.Git.Runtime`) so they behave exactly like the user's own git:
  hooks run, LFS filters apply, the user's config and credential helpers are
  honoured. Every function takes the repository (or working tree) directory.

  Commands run through `Longx.Shim` — stdout and stderr come back
  separately and a hung command is killed with its process tree.
  """

  alias Longx.Git.Runtime
  alias Longx.Platform
  alias Longx.Shim

  defmodule Error do
    @moduledoc "A git command that exited non-zero."
    defexception [:args, :status, :stdout, :stderr]

    @type t :: %__MODULE__{args: [String.t()], status: integer, stdout: binary, stderr: binary}

    @impl true
    def message(%__MODULE__{args: args, status: status, stderr: stderr}),
      do: "git #{Enum.join(args, " ")} exited #{status}: #{String.trim(stderr)}"
  end

  @type change :: %{path: String.t(), status: atom}
  @type status :: %{clean?: boolean, changes: [change]}
  @type log_entry :: %{sha: String.t(), subject: String.t(), author: String.t(), at: DateTime.t()}

  # Identity for commits Longx makes when the user has none configured.
  @fallback_identity ["-c", "user.name=Longx", "-c", "user.email=longx@localhost"]

  ## Running git

  @doc "The bundled git binary. Raises if `mix git.fetch` has not run."
  @spec executable() :: Path.t()
  def executable do
    case Runtime.executable() do
      {:ok, exe} -> exe
      {:error, :not_installed} -> raise "bundled git is not installed; run `mix git.fetch`"
    end
  end

  @doc """
  Runs `git args` in `opts[:cd]`. `{:ok, %{status: 0, stdout, stderr}}` on
  success, `{:error, %Longx.Git.Error{}}` on a non-zero exit, `{:error, :timeout}`
  when `opts[:timeout]` (default 60 s) passes. Extra `env:` entries are added
  to the bundle's environment.
  """
  @spec run([String.t()], keyword) ::
          {:ok, %{status: 0, stdout: binary, stderr: binary}} | {:error, Error.t() | term}
  def run(args, opts \\ []) do
    env =
      Runtime.env(Runtime.root(), Platform.current(), System.get_env()) ++
        Keyword.get(opts, :env, [])

    shim_opts = [
      env: env,
      cd: Keyword.get(opts, :cd),
      timeout: Keyword.get(opts, :timeout, 60_000)
    ]

    case Shim.run([executable() | args], shim_opts) do
      {:ok, %{status: 0} = result} ->
        {:ok, result}

      {:ok, %{status: status, stdout: out, stderr: err}} ->
        {:error, %Error{args: args, status: status, stdout: out, stderr: err}}

      {:error, _} = error ->
        error
    end
  end

  defp stdout!(args, opts) do
    case run(args, opts) do
      {:ok, %{stdout: out}} -> out
      {:error, %Error{} = error} -> raise error
      {:error, reason} -> raise "git #{Enum.join(args, " ")} failed: #{inspect(reason)}"
    end
  end

  @spec version() :: String.t()
  def version,
    do: stdout!(["--version"], []) |> String.trim() |> String.replace_prefix("git version ", "")

  @spec lfs_version() :: String.t()
  def lfs_version, do: stdout!(["lfs", "version"], []) |> String.trim()

  ## Repositories

  @spec repository?(Path.t()) :: boolean
  def repository?(dir), do: match?({:ok, _}, toplevel(dir))

  @doc "Root of the working tree `dir` belongs to."
  @spec toplevel(Path.t()) :: {:ok, Path.t()} | {:error, :not_a_repository}
  def toplevel(dir) do
    case run(["rev-parse", "--show-toplevel"], cd: dir) do
      {:ok, %{stdout: out}} -> {:ok, String.trim(out)}
      {:error, _} -> {:error, :not_a_repository}
    end
  end

  @spec init(Path.t()) :: :ok | {:error, term}
  def init(dir) do
    with {:ok, _} <- run(["init", "-q"], cd: dir), do: :ok
  end

  @spec head(Path.t()) :: {:ok, String.t()} | {:error, :unborn | term}
  def head(dir) do
    case run(["rev-parse", "--verify", "-q", "HEAD"], cd: dir) do
      {:ok, %{stdout: out}} -> {:ok, String.trim(out)}
      {:error, %Error{status: 1}} -> {:error, :unborn}
      {:error, _} = error -> error
    end
  end

  ## Working tree

  @status_codes %{
    "M" => :modified,
    "A" => :added,
    "D" => :deleted,
    "R" => :renamed,
    "C" => :copied,
    "T" => :type_changed,
    "U" => :unmerged,
    "?" => :untracked,
    "!" => :ignored
  }

  @doc "Porcelain status: untracked files count as changes."
  @spec status(Path.t()) :: status
  def status(dir) do
    changes =
      ["status", "--porcelain=v1", "-z", "--untracked-files=all"]
      |> stdout!(cd: dir)
      |> parse_status()

    %{clean?: changes == [], changes: changes}
  end

  defp parse_status(""), do: []

  defp parse_status(out) do
    out
    |> String.split(<<0>>, trim: true)
    |> Enum.reduce({[], false}, fn
      # the entry after a rename is its original path; skip it
      _orig, {acc, true} ->
        {acc, false}

      <<x, y, ?\s, path::binary>>, {acc, false} ->
        code = if x == ?\s, do: <<y>>, else: <<x>>

        {[%{path: path, status: Map.get(@status_codes, code, :unknown)} | acc],
         code in ["R", "C"]}

      _other, state ->
        state
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc """
  Stages everything and commits. Returns the new commit, or the current HEAD
  when there was nothing to commit. Uses Longx's identity if the user has none.
  """
  @spec commit_all(Path.t(), String.t(), keyword) :: {:ok, String.t()} | {:error, term}
  def commit_all(dir, message, opts \\ []) do
    env = Keyword.get(opts, :env, [])

    with {:ok, _} <- run(["add", "-A"], cd: dir, env: env),
         %{clean?: clean?} <- status_index(dir, env),
         {:ok, _} <- if(clean?, do: {:ok, :nothing}, else: do_commit(dir, message, env)) do
      head(dir)
    end
  end

  defp status_index(dir, env) do
    case run(["diff", "--cached", "--quiet"], cd: dir, env: env) do
      {:ok, _} -> %{clean?: true}
      {:error, %Error{status: 1}} -> %{clean?: false}
      {:error, %Error{status: 128}} -> %{clean?: false}
    end
  end

  defp do_commit(dir, message, env) do
    identity = if configured_identity?(dir, env), do: [], else: @fallback_identity
    run(identity ++ ["commit", "-q", "-m", message], cd: dir, env: env)
  end

  defp configured_identity?(dir, env) do
    match?({:ok, _}, run(["config", "--get", "user.email"], cd: dir, env: env))
  end

  @spec log(Path.t(), keyword) :: [log_entry]
  def log(dir, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    case run(["log", "-z", "--format=%H%x1f%s%x1f%an%x1f%aI", "-n", Integer.to_string(limit)],
           cd: dir
         ) do
      {:ok, %{stdout: ""}} ->
        []

      {:ok, %{stdout: out}} ->
        out
        |> String.split(<<0>>, trim: true)
        |> Enum.map(fn line ->
          [sha, subject, author, at] = String.split(line, <<0x1F>>, parts: 4)
          {:ok, at, _} = DateTime.from_iso8601(at)
          %{sha: sha, subject: subject, author: author, at: at}
        end)

      {:error, %Error{status: 128}} ->
        []
    end
  end

  @doc "Unified diff between `from` and `to` (default: the working tree)."
  @spec diff(Path.t(), String.t(), String.t() | nil) :: String.t()
  def diff(dir, from, to \\ nil) do
    stdout!(["diff", "--no-color", from | List.wrap(to)], cd: dir)
  end

  @doc """
  Makes the working tree and index match `sha` (tracked files restored or
  removed, untracked files cleaned) *without* moving the branch: history is
  untouched, so this is the safe way to "go back to how the files were".
  """
  @spec restore_tree(Path.t(), String.t()) :: :ok | {:error, term}
  def restore_tree(dir, sha) do
    with {:ok, _} <-
           run(["restore", "--source=" <> sha, "--staged", "--worktree", "--", "."], cd: dir),
         {:ok, _} <- run(["clean", "-fd"], cd: dir),
         do: :ok
  end

  @doc "`git reset --hard sha` + clean untracked. Moves the branch; the reflog keeps the old tip."
  @spec reset_hard(Path.t(), String.t()) :: :ok | {:error, term}
  def reset_hard(dir, sha) do
    with {:ok, _} <- run(["reset", "-q", "--hard", sha], cd: dir),
         {:ok, _} <- run(["clean", "-fd"], cd: dir),
         do: :ok
  end

  ## Worktrees

  @spec worktree_add(Path.t(), Path.t(), String.t()) :: :ok | {:error, term}
  def worktree_add(repo, path, base) do
    with {:ok, _} <- run(["worktree", "add", "--detach", "-q", path, base], cd: repo), do: :ok
  end

  @spec worktree_remove(Path.t(), Path.t()) :: :ok | {:error, term}
  def worktree_remove(repo, path) do
    with {:ok, _} <- run(["worktree", "remove", "--force", path], cd: repo), do: :ok
  end

  @spec worktree_list(Path.t()) :: [
          %{path: Path.t(), head: String.t() | nil, branch: String.t() | nil}
        ]
  def worktree_list(repo) do
    ["worktree", "list", "--porcelain"]
    |> stdout!(cd: repo)
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn block ->
      block
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{path: nil, head: nil, branch: nil}, fn
        "worktree " <> path, acc -> %{acc | path: path}
        "HEAD " <> sha, acc -> %{acc | head: sha}
        "branch " <> ref, acc -> %{acc | branch: ref}
        _, acc -> acc
      end)
    end)
  end

  ## LFS

  @doc "Whether any path in the repository is LFS-tracked (via `.gitattributes`)."
  @spec lfs?(Path.t()) :: boolean
  def lfs?(dir) do
    case run(["check-attr", "-a", "--", ".gitattributes"], cd: dir) do
      {:ok, _} ->
        dir
        |> Path.join("**/.gitattributes")
        |> Path.wildcard(match_dot: true)
        |> Kernel.++(List.wrap(Path.join(dir, ".gitattributes")))
        |> Enum.uniq()
        |> Enum.filter(&File.regular?/1)
        |> Enum.any?(&(File.read!(&1) =~ "filter=lfs"))

      {:error, _} ->
        false
    end
  end
end
