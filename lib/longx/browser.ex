defmodule Longx.Browser do
  @moduledoc """
  Pages as a real browser sees them, for `web.run`'s `open` on JavaScript
  sites and for the agent's browser tools. Each fetch is one short-lived
  `obscura fetch` process run through `Longx.Shim` (killed with its tree at
  the deadline, `oom_score_adj` behind the BEAM, optional memory cap); the
  number running at once is held by `Longx.Browser.Pool`. An idle system
  runs no browser at all. Stateful sessions (clicking, logging in) are the
  next step and will use `obscura serve` behind the same pool, with idle
  shutdown and recycling.

  `config :longx, Longx.Browser`:
    * `executable:` — overrides `Longx.Browser.Runtime` (tests: the fake)
    * `max_concurrent:` / `queue_timeout:` — see `Longx.Browser.Pool`
    * `timeout:` — navigation deadline per fetch, ms (default 30 s)
    * `allow_private_network:` — obscura refuses private / loopback IPs
      (SSRF protection; agents drive this) unless allowed: by this config, by
      the person's switch (`set_allow_private_network/1`, Settings → 工具 —
      a fake-ip network resolves every site to a private address and obscura
      has no per-range allowance, so the switch is all or nothing), or by the
      call's own `allow_private_network:` (tests against a local Bypass)
    * `stealth:` — obscura's consistent-fingerprint mode
    * `memory_limit:` — bytes, `Longx.Shim` `memory_limit` (V8 reserves a lot
      of address space; leave nil unless you know the box)
  """

  alias Longx.Browser.{Html, Installer, Pool, Runtime}
  alias Longx.Shim

  require Logger

  @type format :: :html | :markdown | :text
  @type page :: %{
          url: String.t(),
          title: String.t() | nil,
          format: format,
          content: String.t(),
          truncated: boolean,
          stderr: String.t()
        }

  @default_timeout 30_000
  @default_max_bytes 512_000
  @oom_score_adj 600

  @doc "The browser can run here (installed, or pointed at by the configuration)."
  @spec available?() :: boolean
  def available?, do: match?({:ok, _}, executable())

  @doc """
  Renders `url` and returns its content. Options: `format:` (`:html` — the
  cleaned main element, default — `:markdown`, `:text`), `timeout:` ms,
  `wait_until:` (`:load` | `:domcontentloaded` | `:networkidle0`),
  `selector:` (wait for it), `wait:` seconds of settle, `max_bytes:`,
  `queue_timeout:`.
  """
  @spec fetch(String.t(), keyword) :: {:ok, page} | {:error, term}
  def fetch(url, opts \\ []) do
    with :ok <- check_url(url),
         {:ok, exe} <- executable() do
      Pool.run(fn -> run(exe, url, opts) end, Keyword.take(opts, [:queue_timeout]))
    else
      # not installed and nothing configured in its place: the first need starts
      # the download; the caller (the agent's web_fetch) hears how far it is
      {:error, :not_installed} ->
        case Installer.install() do
          :ok -> {:error, {:installing, Installer.status()}}
          {:error, :unsupported_platform} -> {:error, :unavailable}
        end

      other ->
        other
    end
  end

  defp run(exe, url, opts) do
    format = Keyword.get(opts, :format, :html)
    timeout = Keyword.get(opts, :timeout, config(:timeout, @default_timeout))
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    start = System.monotonic_time(:millisecond)

    private = Keyword.get_lazy(opts, :allow_private_network, &allow_private_network?/0)

    result =
      Shim.run([exe | args(url, format, timeout, opts, private)],
        env: env(timeout, private),
        # obscura's own deadline first; ours is the backstop that kills the tree
        timeout: timeout + 2_000,
        oom_score_adj: @oom_score_adj,
        memory_limit: config(:memory_limit, nil)
      )

    :telemetry.execute(
      [:longx, :browser, :fetch],
      %{duration_ms: System.monotonic_time(:millisecond) - start},
      %{url: url, format: format, ok: match?({:ok, %{status: 0}}, result)}
    )

    case result do
      {:ok, %{status: 0, stdout: stdout, stderr: stderr}} ->
        {:ok, page(url, format, stdout, stderr, max_bytes)}

      {:ok, %{status: _, stderr: stderr}} ->
        {:error, {:navigation, error_line(stderr)}}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp args(url, format, timeout, opts, private) do
    dump = if format == :html, do: "html", else: Atom.to_string(format)

    [
      "fetch",
      url,
      "--dump",
      dump,
      "--quiet",
      "--timeout",
      Integer.to_string(div(timeout + 999, 1000))
    ]
    |> put_flag("--wait-until", opts[:wait_until] && Atom.to_string(opts[:wait_until]))
    |> put_flag("--selector", opts[:selector])
    |> put_flag("--wait", opts[:wait] && to_string(opts[:wait]))
    |> then(&if(config(:stealth, false), do: &1 ++ ["--stealth"], else: &1))
    |> then(&if(private, do: &1 ++ ["--allow-private-network"], else: &1))
  end

  defp put_flag(args, _flag, nil), do: args
  defp put_flag(args, flag, value), do: args ++ [flag, value]

  defp env(timeout, private) do
    [{"OBSCURA_SCRIPT_DEADLINE_MS", Integer.to_string(timeout)}] ++
      if(private, do: [{"OBSCURA_ALLOW_PRIVATE_NETWORK", "1"}], else: [])
  end

  @private_key "browser_allow_private_network"

  @doc """
  Whether pages at private / loopback addresses may be fetched: the config
  when it says so, else the person's switch (`Longx.System.Setting`).
  """
  @spec allow_private_network?() :: boolean
  def allow_private_network? do
    config(:allow_private_network, false) or
      match?({:ok, %{value: "true"}}, Longx.System.get_setting(@private_key))
  end

  @doc "The person's switch (Settings → 工具): needed on a fake-ip network, where every site resolves to a private address."
  @spec set_allow_private_network(boolean) :: :ok
  def set_allow_private_network(flag) when is_boolean(flag) do
    _ = Longx.System.put_setting!(@private_key, if(flag, do: "true", else: "false"))
    :ok
  end

  defp page(url, format, stdout, stderr, max_bytes) do
    {content, title} =
      case format do
        :html -> {Html.main(stdout), Html.title(stdout) || title_from_log(stderr)}
        _ -> {stdout, title_from_log(stderr)}
      end

    truncated = byte_size(content) > max_bytes
    content = if truncated, do: cut(content, max_bytes), else: content

    %{
      url: url,
      title: title,
      format: format,
      content: content,
      truncated: truncated,
      stderr: stderr
    }
  end

  # obscura logs `Page loaded: <url> - "<title>"` on stderr
  defp title_from_log(stderr) do
    case Regex.run(~r/^Page loaded: .* - "(.*)"$/m, stderr) do
      [_, ""] -> nil
      [_, title] -> title
      _ -> nil
    end
  end

  defp error_line(stderr) do
    stderr
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "Error:"))
    |> case do
      nil -> String.trim(stderr) |> String.slice(0, 300)
      line -> String.replace_prefix(line, "Error: ", "")
    end
  end

  # cut on a character boundary
  defp cut(content, max_bytes) do
    content
    |> binary_part(0, max_bytes)
    |> String.chunk(:valid)
    |> Enum.take(1)
    |> List.first()
    |> then(&(&1 || ""))
  end

  defp check_url("http://" <> _), do: :ok
  defp check_url("https://" <> _), do: :ok
  defp check_url(_), do: {:error, :invalid_url}

  defp executable do
    case config(:executable, nil) do
      nil -> Runtime.executable()
      exe -> if File.regular?(exe), do: {:ok, exe}, else: {:error, :unavailable}
    end
  end

  defp config(key, default) do
    :longx |> Application.get_env(Longx.Browser, []) |> Keyword.get(key, default)
  end
end
