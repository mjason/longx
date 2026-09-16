defmodule Longx.Exec.Env do
  @moduledoc """
  The environment a command runs with, built the way codex's own executor
  builds it (`shell_environment::create_env`) from the `envPolicy` and `env`
  of a `process/start`: inherit the host environment (`all`), only its core
  variables (`core`) or nothing (`none`); drop `exclude` patterns; apply
  `set`; keep only `includeOnly`; then overlay codex's own `env` (its
  `CODEX_*` markers, `LANG`, pagers) on top. No policy means exactly the
  overlay — codex-local does the same.

  Two rules are ours and hold whatever the policy says: names that look like
  secrets (`*KEY*`, `*SECRET*`, `*TOKEN*` — codex's default excludes, which
  codex-local applies too) and Longx's own variables (`LONGX_*`: the gateway
  token, the cloak key) never reach a command, nor do the variables codex
  itself declares non-inheritable.
  """

  @core ~w(PATH SHELL TMPDIR TEMP TMP HOME LANG LC_ALL LC_CTYPE LOGNAME USER)
  @secret_patterns ~w(*KEY* *SECRET* *TOKEN* LONGX_*)
  @non_inheritable ~w(
    CODEX_EXEC_SERVER_NOISE_AUTH_TOKEN NODE_REPL_AUTH_TOKEN OPENAI_FEDERATION_RULE_ID
    OPENAI_IDENTITY_TOKEN_FILE OPENAI_WORKLOAD_IDENTITY_CONTEXT
  )

  @type policy :: %{optional(String.t()) => term} | nil

  @doc """
  The command's environment from the host's, the policy and codex's overlay.
  `tool_bin:` (Longx.Codex.Home.tool_bin/0 — codex's `apply_patch` alias)
  leads `PATH` whatever the policy says: codex's built-in executor has that
  directory on its own PATH, which the command inherits there; here the
  command inherits Longx's.
  """
  @spec build(%{String.t() => String.t()}, policy, %{String.t() => String.t()}, keyword) ::
          %{String.t() => String.t()}
  def build(host, policy, overlay, opts \\ []) do
    policy
    |> inherit(host)
    |> exclude(patterns(policy["exclude"]))
    |> Map.merge(policy["set"] || %{})
    |> include_only(patterns(policy["includeOnly"]))
    |> Map.merge(overlay || %{})
    |> exclude(patterns(@secret_patterns ++ @non_inheritable))
    |> lead_path(Keyword.get(opts, :tool_bin))
  end

  defp lead_path(env, nil), do: env

  defp lead_path(env, dir) do
    case env["PATH"] do
      path when is_binary(path) and path != "" -> Map.put(env, "PATH", dir <> ":" <> path)
      _ -> Map.put(env, "PATH", dir)
    end
  end

  defp inherit(nil, _host), do: %{}
  defp inherit(%{"inherit" => "none"}, _host), do: %{}
  defp inherit(%{"inherit" => "core"}, host), do: Map.take(host, @core)
  defp inherit(_all, host), do: host

  defp exclude(env, []), do: env
  defp exclude(env, patterns), do: Map.reject(env, fn {name, _} -> matches?(name, patterns) end)

  defp include_only(env, []), do: env

  defp include_only(env, patterns),
    do: Map.filter(env, fn {name, _} -> matches?(name, patterns) end)

  defp matches?(name, patterns), do: Enum.any?(patterns, &Regex.match?(&1, name))

  # codex's EnvironmentVariablePattern: a case-insensitive glob (`*`, `?`)
  defp patterns(nil), do: []

  defp patterns(globs) do
    for glob <- globs do
      source = glob |> Regex.escape() |> String.replace("\\*", ".*") |> String.replace("\\?", ".")
      Regex.compile!("\\A#{source}\\z", "i")
    end
  end
end
