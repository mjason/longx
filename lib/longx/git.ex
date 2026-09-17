defmodule Longx.Git do
  @moduledoc """
  Repository operations, performed by the machine's own git (the first `git`
  on PATH; `LONGX_GIT` overrides) so they behave exactly like the user's:
  hooks run, LFS filters apply, the user's config and credential helpers are
  honoured. Every function takes the repository (or working tree) directory.
  A machine without git is not an error to raise about: `available?/0` says
  so, every operation answers `{:error, :no_git}`, a directory is no
  repository, and the callers go on without bookmarks or commits.

  Commands run through `Longx.Shim` — stdout and stderr come back
  separately and a hung command is killed with its process tree.
  """

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
  @type log_entry :: %{
          sha: String.t(),
          subject: String.t(),
          author: String.t(),
          email: String.t(),
          at: DateTime.t()
        }
  @type file_diff :: %{binary: boolean, diff: String.t()}
  @type branch :: %{
          name: String.t(),
          sha: String.t(),
          current: boolean,
          upstream: String.t() | nil
        }

  # Identity for commits Longx makes when the user has none configured.
  @fallback_identity ["-c", "user.name=Longx", "-c", "user.email=longx@localhost"]

  ## Running git

  @doc "The git binary: `LONGX_GIT` when set (and a file), else the first `git` on PATH."
  @spec executable() :: {:ok, Path.t()} | {:error, :no_git}
  def executable do
    case System.get_env("LONGX_GIT") do
      nil ->
        case System.find_executable("git") do
          nil -> {:error, :no_git}
          exe -> {:ok, exe}
        end

      path ->
        if File.regular?(path), do: {:ok, path}, else: {:error, :no_git}
    end
  end

  @doc "Whether this machine has git at all."
  @spec available?() :: boolean
  def available?, do: match?({:ok, _}, executable())

  @doc """
  Runs `git args` in `opts[:cd]`. `{:ok, %{status: 0, stdout, stderr}}` on
  success, `{:error, %Longx.Git.Error{}}` on a non-zero exit, `{:error, :timeout}`
  when `opts[:timeout]` (default 60 s) passes, `{:error, :no_git}` without
  git. Never a prompt (`GIT_TERMINAL_PROMPT=0`), C-locale output; extra
  `env:` entries are added.
  """
  @spec run([String.t()], keyword) ::
          {:ok, %{status: 0, stdout: binary, stderr: binary}} | {:error, Error.t() | term}
  def run(args, opts \\ []) do
    with {:ok, exe} <- executable() do
      env = [{"GIT_TERMINAL_PROMPT", "0"}, {"LC_ALL", "C"}] ++ Keyword.get(opts, :env, [])

      shim_opts = [
        env: env,
        cd: Keyword.get(opts, :cd),
        timeout: Keyword.get(opts, :timeout, 60_000)
      ]

      case Shim.run([exe | args], shim_opts) do
        {:ok, %{status: 0} = result} ->
          {:ok, result}

        {:ok, %{status: status, stdout: out, stderr: err}} ->
          {:error, %Error{args: args, status: status, stdout: out, stderr: err}}

        {:error, _} = error ->
          error
      end
    end
  end

  # no git: empty output, so a status is "clean", a log empty, a version blank
  defp stdout!(args, opts) do
    case run(args, opts) do
      {:ok, %{stdout: out}} -> out
      {:error, :no_git} -> ""
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
    run(identity(dir, env) ++ ["commit", "-q", "-m", message], cd: dir, env: env)
  end

  defp configured_identity?(dir, env) do
    match?({:ok, _}, run(["config", "--get", "user.email"], cd: dir, env: env))
  end

  @doc "Newest first; `limit:` (50) and `skip:` (0) page through the history."
  @spec log(Path.t(), keyword) :: [log_entry]
  def log(dir, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    skip = Keyword.get(opts, :skip, 0)

    args = [
      "log",
      "-z",
      "--format=%H%x1f%s%x1f%an%x1f%ae%x1f%aI",
      "-n",
      Integer.to_string(limit),
      "--skip=#{skip}"
    ]

    case run(args, cd: dir) do
      {:ok, %{stdout: ""}} ->
        []

      {:ok, %{stdout: out}} ->
        out
        |> String.split(<<0>>, trim: true)
        |> Enum.map(fn line ->
          [sha, subject, author, email, at] = String.split(line, <<0x1F>>, parts: 5)
          {:ok, at, _} = DateTime.from_iso8601(at)
          %{sha: sha, subject: subject, author: author, email: email, at: at}
        end)

      {:error, %Error{status: 128}} ->
        []
    end
  end

  @doc """
  One commit for the history view: message (subject + body), author, time,
  parents and the files it touched with their status.
  """
  @spec show(Path.t(), String.t()) ::
          %{
            sha: String.t(),
            subject: String.t(),
            body: String.t(),
            author: String.t(),
            email: String.t(),
            at: DateTime.t(),
            parents: [String.t()],
            files: [change]
          }
          | {:error, term}
  def show(dir, sha) do
    format = "--format=%H%x1f%s%x1f%b%x1f%an%x1f%ae%x1f%aI%x1f%P%x1e"

    # a merge commit shows what it brought in, against its first parent
    with {:ok, %{stdout: out}} <-
           run(
             [
               "show",
               "--name-status",
               "-z",
               "--diff-merges=first-parent",
               format,
               "--no-color",
               sha
             ],
             cd: dir
           ),
         [header, files] <- String.split(out, <<0x1E>>, parts: 2) do
      [sha, subject, body, author, email, at, parents] = String.split(header, <<0x1F>>, parts: 7)
      {:ok, at, _} = DateTime.from_iso8601(at)

      %{
        sha: sha,
        subject: subject,
        body: String.trim(body),
        author: author,
        email: email,
        at: at,
        parents: String.split(parents, " ", trim: true),
        # the file list starts after a NUL and a newline
        files: files |> String.trim_leading(<<0>>) |> String.trim_leading() |> parse_name_status()
      }
    else
      {:error, _} = error -> error
      _ -> {:error, :unparsable}
    end
  end

  # `--name-status -z`: STATUS NUL PATH NUL (renames / copies: STATUS NUL OLD NUL NEW NUL)
  defp parse_name_status(out), do: out |> String.split(<<0>>, trim: true) |> name_status([])

  defp name_status([], acc), do: Enum.reverse(acc)

  defp name_status([<<code, _::binary>>, _old, new | rest], acc) when code in [?R, ?C],
    do: name_status(rest, [%{path: new, status: Map.fetch!(@status_codes, <<code>>)} | acc])

  defp name_status([<<code, _::binary>>, path | rest], acc),
    do:
      name_status(rest, [%{path: path, status: Map.get(@status_codes, <<code>>, :unknown)} | acc])

  defp name_status([_dangling], acc), do: Enum.reverse(acc)

  @doc "What one commit did to one file (the root commit against the empty tree)."
  @spec commit_file_diff(Path.t(), String.t(), String.t()) :: file_diff | {:error, term}
  def commit_file_diff(dir, sha, path) do
    case run(["show", "--format=", "--no-color", "--diff-merges=first-parent", sha, "--", path],
           cd: dir
         ) do
      {:ok, %{stdout: out}} -> as_file_diff(out)
      {:error, _} = error -> error
    end
  end

  @doc """
  The working tree's change to one file against HEAD: a modified, deleted or
  untracked file (the latter diffed against nothing). `binary` when git
  cannot show it as text.
  """
  @spec file_diff(Path.t(), String.t()) :: file_diff
  def file_diff(dir, path) do
    tracked? = match?({:ok, _}, run(["ls-files", "--error-unmatch", "--", path], cd: dir))

    if tracked? do
      case run(["diff", "--no-color", "HEAD", "--", path], cd: dir) do
        {:ok, %{stdout: out}} -> as_file_diff(out)
        {:error, %Error{stdout: out}} -> as_file_diff(out)
      end
    else
      # git diff --no-index exits 1 when the files differ, which they do
      case run(["diff", "--no-color", "--no-index", "--", "/dev/null", path], cd: dir) do
        {:ok, %{stdout: out}} -> as_file_diff(out)
        {:error, %Error{status: 1, stdout: out}} -> as_file_diff(out)
        {:error, %Error{}} -> %{binary: false, diff: ""}
      end
    end
  end

  defp as_file_diff(out), do: %{binary: String.contains?(out, "Binary files"), diff: out}

  @doc """
  Both sides of one file's change, whole — what a side-by-side view needs
  rather than a patch. `sha` nil: HEAD's text against the working tree;
  a sha: the file at the commit's first parent against the commit. A side
  where the file does not exist is nil; a binary on either side flags the
  pair and carries no text.
  """
  @spec file_versions(Path.t(), String.t() | nil, String.t()) :: %{
          before: String.t() | nil,
          after: String.t() | nil,
          binary: boolean
        }
  def file_versions(dir, nil, path) do
    after_text =
      case File.read(Path.join(dir, path)) do
        {:ok, text} -> text
        {:error, _} -> nil
      end

    versions(file_at(dir, "HEAD", path), after_text)
  end

  def file_versions(dir, sha, path),
    do: versions(file_at(dir, sha <> "^", path), file_at(dir, sha, path))

  defp versions(before_text, after_text) do
    if Enum.any?([before_text, after_text], &binary_text?/1),
      do: %{before: nil, after: nil, binary: true},
      else: %{before: before_text, after: after_text, binary: false}
  end

  # the file's content at a revision, nil when it (or the revision) is not there
  defp file_at(dir, rev, path) do
    case run(["show", rev <> ":" <> path], cd: dir) do
      {:ok, %{stdout: out}} -> out
      {:error, _} -> nil
    end
  end

  defp binary_text?(nil), do: false

  defp binary_text?(text) do
    head = binary_part(text, 0, min(byte_size(text), 8_192))
    String.contains?(head, <<0>>) or not String.valid?(head)
  end

  @doc "What `.gitignore` hides, ignored directories as a whole (`build/`)."
  @spec ignored(Path.t()) :: [String.t()]
  def ignored(dir) do
    ["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"]
    |> stdout!(cd: dir)
    |> String.split(<<0>>, trim: true)
  end

  @doc "A merge is in progress (a pull or merge stopped on conflicts)."
  @spec merging?(Path.t()) :: boolean
  def merging?(dir) do
    case run(["rev-parse", "--verify", "-q", "MERGE_HEAD"], cd: dir) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @spec abort_merge(Path.t()) :: :ok | {:error, term}
  def abort_merge(dir) do
    with {:ok, _} <- run(["merge", "--abort"], cd: dir), do: :ok
  end

  @doc """
  Commits the named paths only (untracked ones included, deletions too);
  the other changes stay in the working tree. `{:error, :nothing_to_commit}`
  when the paths carry no change. Uses Longx's identity if the user has none.
  During a merge git allows no partial commit: the paths are staged and the
  merge committed whole.
  """
  @spec commit(Path.t(), String.t(), keyword) ::
          {:ok, String.t()} | {:error, :nothing_to_commit | term}
  def commit(dir, message, opts) do
    paths = Keyword.fetch!(opts, :paths)
    env = Keyword.get(opts, :env, [])
    identity = identity(dir, env)

    only = if merging?(dir), do: [], else: ["--" | paths]

    with {:ok, _} <- run(["add", "-A", "--"] ++ paths, cd: dir, env: env),
         {:ok, _} <-
           run(["diff", "--cached", "--quiet", "--"] ++ paths, cd: dir, env: env)
           |> nothing_when_clean(),
         {:ok, _} <- run(identity ++ ["commit", "-q", "-m", message] ++ only, cd: dir, env: env) do
      head(dir)
    end
  end

  # `diff --quiet` exits 0 when nothing differs, 1 when something does
  defp nothing_when_clean({:ok, _}), do: {:error, :nothing_to_commit}
  defp nothing_when_clean({:error, %Error{status: 1}}), do: {:ok, :changes}
  defp nothing_when_clean(other), do: other

  @doc "Puts the named tracked files back to HEAD and removes the named untracked ones."
  @spec discard(Path.t(), [String.t()]) :: :ok | {:error, term}
  def discard(dir, paths) do
    {tracked, untracked} =
      Enum.split_with(
        paths,
        &match?({:ok, _}, run(["ls-files", "--error-unmatch", "--", &1], cd: dir))
      )

    with {:ok, _} <- restore_paths(dir, tracked),
         {:ok, _} <- clean_paths(dir, untracked),
         do: :ok
  end

  defp restore_paths(_dir, []), do: {:ok, :none}

  defp restore_paths(dir, paths),
    do: run(["restore", "--source=HEAD", "--staged", "--worktree", "--"] ++ paths, cd: dir)

  defp clean_paths(_dir, []), do: {:ok, :none}
  defp clean_paths(dir, paths), do: run(["clean", "-f", "--"] ++ paths, cd: dir)

  @doc """
  Takes the last commit back into the working tree (its changes stay, as
  changes): `reset --soft HEAD~1`. The root commit cannot be undone.
  """
  @spec undo_commit(Path.t()) :: {:ok, String.t()} | {:error, :root_commit | term}
  def undo_commit(dir) do
    case run(["rev-parse", "--verify", "-q", "HEAD~1"], cd: dir) do
      {:ok, %{stdout: parent}} ->
        with {:ok, _} <- run(["reset", "-q", "--soft", "HEAD~1"], cd: dir),
             do: {:ok, String.trim(parent)}

      {:error, %Error{status: 1}} ->
        {:error, :root_commit}

      {:error, _} = error ->
        error
    end
  end

  ## Branches

  @doc "Local branches with the current one marked (`current: nil` when HEAD is detached)."
  @spec branches(Path.t()) :: %{current: String.t() | nil, branches: [branch]}
  def branches(dir) do
    current =
      case run(["symbolic-ref", "--short", "-q", "HEAD"], cd: dir) do
        {:ok, %{stdout: out}} -> String.trim(out)
        {:error, _} -> nil
      end

    branches =
      [
        "for-each-ref",
        "--format=%(refname:short)%1f%(objectname)%1f%(upstream:short)",
        "refs/heads"
      ]
      |> stdout!(cd: dir)
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        [name, sha, upstream] = String.split(line, <<0x1F>>, parts: 3)

        %{
          name: name,
          sha: sha,
          current: name == current,
          upstream: if(upstream == "", do: nil, else: upstream)
        }
      end)

    %{current: current, branches: branches}
  end

  @spec create_branch(Path.t(), String.t()) :: :ok | {:error, term}
  def create_branch(dir, name) do
    with {:ok, _} <- run(["switch", "-q", "-c", name], cd: dir), do: :ok
  end

  @doc "Checks the branch out; fails (rather than carrying changes over) when they are in the way."
  @spec switch(Path.t(), String.t()) :: :ok | {:error, term}
  def switch(dir, name) do
    with {:ok, _} <- run(["switch", "-q", name], cd: dir), do: :ok
  end

  @spec delete_branch(Path.t(), String.t(), keyword) :: :ok | {:error, term}
  def delete_branch(dir, name, opts \\ []) do
    flag = if Keyword.get(opts, :force, false), do: "-D", else: "-d"
    with {:ok, _} <- run(["branch", "-q", flag, name], cd: dir), do: :ok
  end

  @doc "Sets the working tree aside (untracked files too) so a branch can be switched."
  @spec stash(Path.t(), String.t()) :: :ok | {:error, term}
  def stash(dir, message) do
    with {:ok, _} <- run(["stash", "push", "-q", "-u", "-m", message], cd: dir), do: :ok
  end

  @spec stash_pop(Path.t()) :: :ok | {:error, term}
  def stash_pop(dir) do
    with {:ok, _} <- run(["stash", "pop", "-q"], cd: dir), do: :ok
  end

  @spec stashes(Path.t()) :: [%{index: non_neg_integer, message: String.t()}]
  def stashes(dir) do
    ["stash", "list", "--format=%gd%x1f%gs"]
    |> stdout!(cd: dir)
    |> String.split("\n", trim: true)
    |> Enum.with_index()
    |> Enum.map(fn {line, index} ->
      [_ref, message] = String.split(line, <<0x1F>>, parts: 2)
      %{index: index, message: message}
    end)
  end

  ## Remotes

  @remote_timeout 120_000

  @spec remotes(Path.t()) :: [%{name: String.t(), url: String.t()}]
  def remotes(dir) do
    ["remote", "-v"]
    |> stdout!(cd: dir)
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, ~r/\s+/, parts: 3) do
        [name, url, "(fetch)"] -> [%{name: name, url: url}]
        _ -> []
      end
    end)
  end

  @doc "Adds the remote, or points an existing one at `url`."
  @spec set_remote(Path.t(), String.t(), String.t()) :: :ok | {:error, term}
  def set_remote(dir, name, url) do
    if Enum.any?(remotes(dir), &(&1.name == name)) do
      with {:ok, _} <- run(["remote", "set-url", name, url], cd: dir), do: :ok
    else
      with {:ok, _} <- run(["remote", "add", name, url], cd: dir), do: :ok
    end
  end

  @doc "Commits ahead of / behind the upstream, or nil without one."
  @spec ahead_behind(Path.t()) :: %{ahead: non_neg_integer, behind: non_neg_integer} | nil
  def ahead_behind(dir) do
    case run(["rev-list", "--left-right", "--count", "@{u}...HEAD"], cd: dir) do
      {:ok, %{stdout: out}} ->
        [behind, ahead] =
          out |> String.trim() |> String.split(~r/\s+/) |> Enum.map(&String.to_integer/1)

        %{ahead: ahead, behind: behind}

      {:error, _} ->
        nil
    end
  end

  @spec fetch(Path.t()) :: :ok | {:error, term}
  def fetch(dir) do
    with {:ok, _} <- run(["fetch", "-q", "--prune"], cd: dir, timeout: @remote_timeout), do: :ok
  end

  @spec pull(Path.t()) :: :ok | {:error, term}
  def pull(dir) do
    # a pull may end in a merge commit, which needs an identity like any commit
    with {:ok, _} <-
           run(identity(dir, []) ++ ["pull", "-q", "--no-rebase"],
             cd: dir,
             timeout: @remote_timeout
           ),
         do: :ok
  end

  @doc """
  Merges `branch` into the current one (a merge commit under Longx's identity
  when the user has none). `{:error, :conflict}` leaves the merge in progress
  for `commit/3` or `abort_merge/1`.
  """
  @spec merge(Path.t(), String.t(), keyword) :: :ok | {:error, :conflict | term}
  def merge(dir, branch, opts \\ []) do
    no_ff = if Keyword.get(opts, :no_ff, false), do: ["--no-ff"], else: []
    message = if msg = Keyword.get(opts, :message), do: ["-m", msg], else: []

    case run(identity(dir, []) ++ ["merge", "-q"] ++ no_ff ++ message ++ [branch], cd: dir) do
      {:ok, _} -> :ok
      {:error, %Error{}} = error -> if merging?(dir), do: {:error, :conflict}, else: error
      {:error, _} = error -> error
    end
  end

  # the `-c user.*` fallback, unless an identity is configured
  defp identity(dir, env),
    do: if(configured_identity?(dir, env), do: [], else: @fallback_identity)

  @doc "Pushes the current branch, setting its upstream on `origin` the first time."
  @spec push(Path.t()) :: :ok | {:error, term}
  def push(dir) do
    args =
      case branches(dir) do
        %{current: nil} ->
          ["push", "-q"]

        %{current: name, branches: branches} ->
          case Enum.find(branches, &(&1.name == name)) do
            %{upstream: nil} -> ["push", "-q", "-u", "origin", name]
            _ -> ["push", "-q"]
          end
      end

    with {:ok, _} <- run(args, cd: dir, timeout: @remote_timeout), do: :ok
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
