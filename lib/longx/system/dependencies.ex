defmodule Longx.System.Dependencies do
  @moduledoc """
  The command-line tools the agent's shell work leans on — `rg`, `fd`,
  `fzf`, `bat`, `jq`, `tree`, `git`, `gh`, `delta` — looked up on PATH
  (under each spelling a distribution uses: `fdfind`, `batcat`) with their
  versions, and the one install line for this platform for whatever is
  missing. Detection only: Longx never installs anything; the settings
  page shows the line and the status strip counts what is missing.
  `report/1` caches for ten minutes (`force: true` runs again).
  """

  import Bitwise, only: [&&&: 2]

  @tools [
    %{
      name: "ripgrep",
      commands: ["rg"],
      apt: "ripgrep",
      brew: "ripgrep",
      winget: "BurntSushi.ripgrep.MSVC"
    },
    %{
      name: "fd-find",
      commands: ["fd", "fdfind"],
      apt: "fd-find",
      brew: "fd",
      winget: "sharkdp.fd"
    },
    %{name: "fzf", commands: ["fzf"], apt: "fzf", brew: "fzf", winget: "junegunn.fzf"},
    %{name: "bat", commands: ["bat", "batcat"], apt: "bat", brew: "bat", winget: "sharkdp.bat"},
    %{name: "jq", commands: ["jq"], apt: "jq", brew: "jq", winget: "jqlang.jq"},
    %{name: "tree", commands: ["tree"], apt: "tree", brew: "tree", winget: nil},
    %{name: "git", commands: ["git"], apt: "git", brew: "git", winget: "Git.Git"},
    %{name: "gh", commands: ["gh"], apt: "gh", brew: "gh", winget: "GitHub.cli"},
    %{
      name: "git-delta",
      commands: ["delta"],
      apt: "git-delta",
      brew: "git-delta",
      winget: "dandavison.delta"
    }
  ]

  @version_timeout 2_000
  @ttl_ms 10 * 60_000
  @key {__MODULE__, :report}

  @type tool :: %{
          name: String.t(),
          command: String.t(),
          found: boolean,
          path: String.t() | nil,
          version: String.t() | nil,
          install: %{apt: String.t(), brew: String.t(), winget: String.t() | nil}
        }

  @type report :: %{
          os: String.t(),
          tools: [tool],
          missing: non_neg_integer,
          install_command: String.t() | nil,
          checked_at: DateTime.t()
        }

  @doc "The cached report, or a fresh one when none, stale (10 min) or `force: true`."
  @spec report(keyword) :: report
  def report(opts \\ []) do
    now = System.monotonic_time(:millisecond)

    case {Keyword.get(opts, :force, false), :persistent_term.get(@key, nil)} do
      {false, {at, report}} when now - at < @ttl_ms ->
        report

      _ ->
        report = check(opts)
        :persistent_term.put(@key, {now, report})
        report
    end
  end

  @doc "Drops the cache (tests)."
  @spec forget() :: :ok
  def forget do
    :persistent_term.erase(@key)
    :ok
  end

  @doc """
  Looks every tool up now. `path:` the PATH to search (the environment's
  by default), `os:` the platform (`Longx.Platform` by default).
  """
  @spec check(keyword) :: report
  def check(opts \\ []) do
    dirs =
      opts
      |> Keyword.get(:path, System.get_env("PATH") || "")
      |> String.split(path_separator(), trim: true)

    os = Keyword.get(opts, :os, Longx.Platform.current() |> elem(0))
    tools = Enum.map(@tools, &look_up(&1, dirs, os))
    missing = Enum.filter(tools, &(not &1.found))

    %{
      os: os_name(os),
      tools: tools,
      missing: length(missing),
      install_command: install_command(os, missing),
      checked_at: DateTime.utc_now()
    }
  end

  defp look_up(spec, dirs, os) do
    found =
      Enum.find_value(spec.commands, fn command ->
        case find(command, dirs, os) do
          nil -> nil
          path -> {command, path}
        end
      end)

    base = %{
      name: spec.name,
      install: %{apt: spec.apt, brew: spec.brew, winget: spec.winget}
    }

    case found do
      nil ->
        Map.merge(base, %{command: hd(spec.commands), found: false, path: nil, version: nil})

      {command, path} ->
        Map.merge(base, %{command: command, found: true, path: path, version: version_of(path)})
    end
  end

  defp find(command, dirs, os) do
    names =
      if os == :windows, do: [command <> ".exe", command <> ".cmd", command], else: [command]

    Enum.find_value(dirs, fn dir ->
      Enum.find_value(names, fn name ->
        file = Path.join(dir, name)
        if executable?(file), do: file
      end)
    end)
  end

  defp executable?(file) do
    case File.stat(file) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> (mode &&& 0o111) != 0
      _ -> false
    end
  end

  # `--version` through the shim, killed with its tree after two seconds — a
  # tool that hangs is found, its version unknown
  defp version_of(path) do
    case Longx.Shim.run([path, "--version"], timeout: @version_timeout) do
      {:ok, %{stdout: out, stderr: err}} -> parse_version(out <> "\n" <> err)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp parse_version(text) do
    case Regex.run(~r/(\d+\.\d+(?:\.\d+)?)/, text) do
      [_, version] -> version
      _ -> nil
    end
  end

  defp install_command(_os, []), do: nil

  defp install_command(:darwin, missing),
    do: "brew install " <> Enum.map_join(missing, " ", & &1.install.brew)

  defp install_command(:windows, missing) do
    case Enum.reject(missing, &is_nil(&1.install.winget)) do
      [] -> nil
      tools -> Enum.map_join(tools, " ; ", &"winget install --id #{&1.install.winget}")
    end
  end

  defp install_command(_linux, missing),
    do: "sudo apt install " <> Enum.map_join(missing, " ", & &1.install.apt)

  defp os_name(:darwin), do: "darwin"
  defp os_name(:windows), do: "windows"
  defp os_name(_), do: "linux"

  defp path_separator, do: if(match?({:win32, _}, :os.type()), do: ";", else: ":")
end
