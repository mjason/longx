defmodule Longx.Chrome do
  @moduledoc """
  The person's browsers, reached through the Longx Chrome extension
  (`docs/browser-design.md`). Longx runs on a server and the browser is on
  the person's machine, so the extension connects **out** to Longx
  (`LongxWeb.ChromeSocket`, channel `chrome:bridge`) and relays
  allow-listed `chrome.*` calls — `chrome.debugger` commands above all —
  the way Playwright's extension does; every rule lives here.

  Pairing: an extension connecting without a token is a `pending`
  `Longx.Chrome.Browser` row until the person allows it in Settings →
  浏览器 (`approve/1`: a token, sent once, its sha256 kept); it connects
  with the token from then on. `Longx.Chrome.Aliases` names browsers for
  descriptions (`plug Browser, browser: "qa-chrome"`).
  `Longx.Chrome.Connection` is the live side (`call/4`);
  `Longx.Chrome.Session` a conversation's tabs and JavaScript runtime.
  """

  use Ash.Domain, otp_app: :longx, extensions: [AshGraphql.Domain]

  alias Longx.Chrome.{Aliases, Browser, Bridge, Connection}

  graphql do
    # every error at the top level of the response, for calls and records alike
    root_level_errors? true

    queries do
      action Bridge, :list_chrome_browsers, :list_chrome_browsers
      action Bridge, :chrome_aliases, :chrome_aliases
      action Bridge, :chrome_extension, :chrome_extension
    end

    mutations do
      action Bridge, :approve_chrome_browser, :approve_chrome_browser
      action Bridge, :reject_chrome_browser, :reject_chrome_browser
      action Bridge, :revoke_chrome_browser, :revoke_chrome_browser
      action Bridge, :rename_chrome_browser, :rename_chrome_browser
      action Bridge, :set_chrome_browser_max_tabs, :set_chrome_browser_max_tabs
      action Bridge, :set_chrome_alias, :set_chrome_alias
      action Bridge, :delete_chrome_alias, :delete_chrome_alias
      action Bridge, :set_chrome_default_alias, :set_chrome_default_alias
    end
  end

  resources do
    resource Bridge

    resource Browser do
      define :register_browser, action: :register
      define :list_browsers, action: :all
      define :get_browser, action: :read, get_by: [:id]
      define :browser_by_install_id, action: :by_install_id, args: [:install_id]
      define :browser_by_token_hash, action: :by_token_hash, args: [:token_hash]
      define :destroy_browser, action: :destroy
    end
  end

  @topic "chrome"

  @doc "PubSub topic of every change to the browsers (the settings page refetches)."
  def topic, do: @topic

  @doc "PubSub topic of one browser's CDP events (`{:chrome_event, browser_id, method, params}`)."
  def events_topic(browser_id), do: "chrome:" <> browser_id

  @doc """
  An extension connecting: with a valid token it is the approved browser;
  without one it is (or becomes again) a pending request under its
  `install_id`; a token nobody has is `{:error, :bad_token}` — the
  extension forgets it and asks again.
  """
  @spec connect(String.t(), String.t() | nil, map) ::
          {:ok, Browser.t()} | {:error, :bad_token | :bad_request}
  def connect(install_id, token, device)
      when is_binary(install_id) and install_id != "" and is_map(device) do
    name = device_name(device)

    case token do
      t when is_binary(t) and t != "" ->
        case browser_by_token_hash(hash(t)) do
          {:ok, %Browser{install_id: ^install_id} = browser} -> seen(browser, name, device)
          _ -> {:error, :bad_token}
        end

      _ ->
        case browser_by_install_id(install_id) do
          {:ok, %Browser{status: :approved}} ->
            # it has a token and did not send it: it must ask again
            {:error, :bad_token}

          {:ok, %Browser{status: :revoked} = browser} ->
            {:ok, browser} = Ash.update(browser, %{}, action: :ask_again)
            notify_pending(browser)
            seen(browser, name, device)

          {:ok, %Browser{} = browser} ->
            seen(browser, name, device)

          {:error, _} ->
            {:ok, browser} =
              register_browser(%{install_id: install_id, name: name, device: device})

            notify_pending(browser)
            changed()
            {:ok, browser}
        end
    end
  end

  def connect(_install_id, _token, _device), do: {:error, :bad_request}

  defp seen(browser, name, device) do
    attrs = %{last_seen_at: DateTime.utc_now(), device: device}
    # the person's own name for it stays; a device-named row follows the device
    # An explicit edit in the extension may replace a server-side display name;
    # ordinary reconnects never do. The revision is kept inside the device map.
    revision = device["name_revision"]
    previous_revision = browser.device["name_revision"]
    previous_revision = if is_integer(previous_revision), do: previous_revision, else: 0
    renamed? = is_integer(revision) and revision > previous_revision

    attrs =
      if renamed? or browser.name == device_name(browser.device),
        do: Map.put(attrs, :name, name),
        else: attrs

    Ash.update(browser, attrs, action: :seen)
  end

  @doc "The person allowed it: the token the extension connects with from now on, sent to it once."
  @spec approve(String.t()) :: {:ok, Browser.t(), String.t()} | {:error, term}
  def approve(id) do
    with {:ok, browser} <- get_browser(id) do
      token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

      with {:ok, browser} <- Ash.update(browser, %{token_hash: hash(token)}, action: :approve) do
        Connection.mark(browser.id, :approved)
        Connection.push(browser.id, "approved", %{"token" => token, "name" => browser.name})
        changed()
        {:ok, browser, token}
      end
    end
  end

  @doc "A pending request the person refused: the row goes, the extension is told."
  @spec reject(String.t()) :: :ok | {:error, term}
  def reject(id) do
    with {:ok, browser} <- get_browser(id) do
      Connection.push(browser.id, "revoked", %{})
      :ok = destroy_browser(browser)
      changed()
      :ok
    end
  end

  @doc "An approved browser the person no longer wants: its token is void, the extension is told."
  @spec revoke(String.t()) :: {:ok, Browser.t()} | {:error, term}
  def revoke(id) do
    with {:ok, browser} <- get_browser(id),
         {:ok, browser} <- Ash.update(browser, %{}, action: :revoke) do
      Connection.mark(browser.id, :pending)
      Connection.push(browser.id, "revoked", %{})
      changed()
      {:ok, browser}
    end
  end

  @spec rename(String.t(), String.t()) :: {:ok, Browser.t()} | {:error, term}
  def rename(id, name) when is_binary(name) do
    with {:ok, browser} <- get_browser(id) do
      Ash.update(browser, %{name: String.trim(name)}, action: :rename)
      |> tap(fn _ -> changed() end)
    end
  end

  @spec set_max_tabs(String.t(), pos_integer) :: {:ok, Browser.t()} | {:error, term}
  def set_max_tabs(id, max) when is_integer(max) and max > 0 do
    with {:ok, browser} <- get_browser(id) do
      Ash.update(browser, %{max_tabs: max}, action: :set_max_tabs) |> tap(fn _ -> changed() end)
    end
  end

  @doc "Connected and approved."
  @spec online?(String.t()) :: boolean
  def online?(id), do: Connection.online?(id)

  @doc "Every browser row with its live state, for the settings page (camelCase: an untyped map crosses the wire as it is)."
  @spec directory() :: [map]
  def directory do
    for browser <- list_browsers!() do
      %{
        id: browser.id,
        name: browser.name,
        device: browser.device,
        status: Atom.to_string(browser.status),
        connected: Connection.connected?(browser.id),
        max_tabs: browser.max_tabs,
        last_seen_at: browser.last_seen_at,
        approved_at: browser.approved_at,
        tabs:
          Enum.map(
            Longx.Chrome.Tabs.of_browser(browser.id),
            &%{thread_id: &1.thread_id, title: &1.title, tabs: &1.tabs}
          ),
        aliases: aliases_of(browser.id)
      }
    end
  end

  defp aliases_of(id), do: for(%{name: name, browsers: ids} <- Aliases.all(), id in ids, do: name)

  defp notify_pending(browser) do
    Longx.Notify.push(%{
      kind: "approval",
      title: "浏览器请求接入：#{browser.name}",
      body: "在 设置 → 浏览器 里允许或拒绝",
      url: "/settings/browsers"
    })
  end

  @extension_zip_path "/extension/longx-chrome.zip"
  @minimum_chrome "118"

  @doc "The built extension's directory (`priv/static/extension/unpacked`; `config :longx, Longx.Chrome, extension_dir:`)."
  def extension_dir do
    Application.get_env(:longx, __MODULE__, [])[:extension_dir] ||
      Path.join(:code.priv_dir(:longx), "static/extension/unpacked")
  end

  @doc "Where the person downloads the extension, and which version is built here."
  def extension_info do
    version = extension_version()

    %{
      url: @extension_zip_path,
      version: version,
      built: version != nil,
      minimum_chrome: @minimum_chrome
    }
  end

  defp extension_version do
    with {:ok, json} <- File.read(Path.join(extension_dir(), "manifest.json")),
         {:ok, %{"version" => version}} <- Jason.decode(json) do
      version
    else
      _ -> nil
    end
  end

  @doc "The built extension zipped in memory (`{:ok, bytes, version}`), or `{:error, :not_built}`."
  def extension_zip do
    dir = extension_dir()

    case extension_version() do
      nil ->
        {:error, :not_built}

      version ->
        files =
          dir
          |> Path.join("**")
          |> Path.wildcard(match_dot: true)
          |> Enum.filter(&File.regular?/1)
          |> Enum.map(&Path.relative_to(&1, dir))
          |> Enum.map(&String.to_charlist/1)

        case :zip.create(~c"longx-chrome.zip", files, [:memory, {:cwd, String.to_charlist(dir)}]) do
          {:ok, {_name, bytes}} -> {:ok, bytes, version}
          {:error, _} -> {:error, :not_built}
        end
    end
  end

  @doc "Where a cell's clipped console output is kept whole: `<dir>/<thread>/cells/<call>.txt`."
  def cell_output_path(thread_id, call_id) do
    dir =
      Application.get_env(:longx, __MODULE__, [])[:dir] || Path.join(File.cwd!(), "data/chrome")

    Path.join([dir, thread_id, "cells", call_id <> ".txt"])
  end

  @doc false
  def changed, do: Phoenix.PubSub.broadcast(Longx.PubSub, @topic, :chrome_changed)

  @doc false
  def hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp device_name(%{"name" => name}) when is_binary(name) and name != "",
    do: String.slice(name, 0, 80)

  defp device_name(_), do: "浏览器"
end
