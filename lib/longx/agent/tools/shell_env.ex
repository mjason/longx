defmodule Longx.Agent.Tools.ShellEnv do
  @moduledoc """
  The environment a command runs in: the person's own shell's, captured
  once per BEAM (codex's *shell snapshot*). A command started by Longx
  would otherwise inherit the BEAM's environment — the shell Longx was
  launched from, or a service's — and `bash -lc` reads bash's files, not
  the `.zshrc` where the PATH with Go, brew, nvm actually is. So
  `snapshot/1` runs `$SHELL -ilc 'env -0'` (interactive and login: every
  file the person's shell reads), parses it, and every `exec_command`
  gets exactly that environment (`env_clear`). `LONGX_*` and the shell's
  own bookkeeping (`PWD`, `SHLVL`, `_`) are dropped; `TERM` is `dumb`.
  A shell that fails to answer falls back to a login shell, then to the
  BEAM's environment. `refresh/0` takes a new snapshot.
  """

  require Logger

  alias Longx.Shim

  @key {__MODULE__, :env}
  @dropped ~w(PWD OLDPWD SHLVL _ TERM)
  @timeout 15_000

  @doc "The person's shell: `$SHELL` when it exists, else bash, else sh."
  @spec shell() :: Path.t()
  def shell do
    Enum.find([System.get_env("SHELL"), "/bin/bash", "/bin/sh"], "/bin/sh", fn
      nil -> false
      path -> File.exists?(path)
    end)
  end

  @doc "The captured environment, as a map (taken on first use)."
  @spec env() :: %{String.t() => String.t()}
  def env do
    case :persistent_term.get(@key, nil) do
      nil ->
        {:ok, env} = refresh()
        env

      env ->
        env
    end
  end

  @doc "The captured environment as the `env:` list a shim takes."
  @spec env_list() :: [{String.t(), String.t()}]
  def env_list, do: Map.to_list(env())

  @doc "Takes a new snapshot (the person changed their shell files)."
  @spec refresh() :: {:ok, map}
  def refresh do
    env =
      case snapshot(shell()) do
        {:ok, env} ->
          env

        {:error, reason} ->
          Logger.warning(
            "agent shell env: no snapshot from #{shell()} (#{inspect(reason)}); using Longx's own environment"
          )

          System.get_env() |> parse_map()
      end

    :persistent_term.put(@key, env)
    {:ok, env}
  end

  @doc "Runs the shell interactively as a login shell and captures its environment."
  @spec snapshot(Path.t()) :: {:ok, map} | {:error, term}
  def snapshot(shell) do
    with {:error, _} <- capture(shell, "-ilc"),
         {:error, _} = error <- capture(shell, "-lc") do
      error
    end
  end

  defp capture(shell, flags) do
    case Shim.run([shell, flags, "env -0"], timeout: @timeout, env: [{"TERM", "dumb"}]) do
      {:ok, %{status: 0, stdout: out}} ->
        env = parse(out)
        if Map.has_key?(env, "PATH"), do: {:ok, env}, else: {:error, :no_path}

      {:ok, %{status: status, stderr: err}} ->
        {:error, {:exit, status, String.slice(err, 0, 200)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Parses `env -0` output; escape sequences and control noise before an entry are dropped."
  @spec parse(binary) :: map
  def parse(output) do
    output
    |> String.split(<<0>>)
    |> Enum.map(&scrub/1)
    |> Enum.flat_map(fn entry ->
      case String.split(entry, "=", parts: 2) do
        [key, value] -> if valid_key?(key), do: [{key, value}], else: []
        _ -> []
      end
    end)
    |> Map.new()
    |> parse_map()
  end

  # what a terminal-minded rc file prints before the first entry (an OSC
  # sequence such as `\e]7;file://…\a`), and stray control characters
  defp scrub(entry) do
    entry
    |> String.replace(~r/\e\][^\a\e]*(\a|\e\\)/, "")
    |> String.replace(~r/\e\[[0-9;?]*[A-Za-z]/, "")
    |> String.replace(~r/^[^A-Za-z_]+/, "")
  end

  defp valid_key?(key), do: Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key)

  defp parse_map(map) do
    map
    |> Enum.reject(fn {k, _} -> k in @dropped or String.starts_with?(k, "LONGX_") end)
    |> Map.new()
    |> Map.put("TERM", "dumb")
  end
end
