defmodule Longx.System.Status do
  @moduledoc "A resource without data: generic actions reporting on this node."

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.System,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name "SystemStatus"
  end

  @browser_fields [
    allow_private_network: [type: :boolean, allow_nil?: false],
    available: [type: :boolean, allow_nil?: false]
  ]

  @upgrade_fields [
    current: [type: :string, allow_nil?: false],
    installed: [type: :boolean, allow_nil?: false],
    latest: [type: :string],
    available: [type: :boolean, allow_nil?: false],
    notes_url: [type: :string],
    checked_at: [type: :string],
    error: [type: :string],
    stage: [
      type: :atom,
      allow_nil?: false,
      constraints: [
        one_of: [:idle, :downloading, :verifying, :installing, :restarting, :installed, :failed]
      ]
    ],
    message: [type: :string],
    target: [type: :string],
    # the tarball's bytes so far while downloading (total nil without a content-length)
    progress: [type: :map],
    has_github_token: [type: :boolean, allow_nil?: false]
  ]

  actions do
    # Settings → codex 进程: every codex process running right now, across
    # projects — what it costs (the tree's RSS, uptime, turns) and when it
    # was last used, which is what the idle reaper (Longx.Codex.Recycler)
    # goes by; `idle_after_ms` is that limit (null: never). Entries are
    # untyped maps (arrays of typed maps are not selectable in ash_typescript
    # 0.18); the shape is typed client-side.
    action :list_codex_processes, :map do
      constraints fields: [
                    processes: [type: {:array, :map}, allow_nil?: false],
                    idle_after_ms: [type: :integer]
                  ]

      run fn _input, _ ->
        {:ok,
         %{
           # an untyped map crosses the wire as is: camelCase it here
           processes: Enum.map(Longx.Projects.running_codex(), &camelize/1),
           idle_after_ms: Longx.Codex.Recycler.idle_after_ms()
         }}
      end
    end

    # The directory picker: subdirectories of `path` (home when omitted),
    # each flagged when it is a git repository. Files are never listed;
    # dot-directories only with `show_hidden`. Paths must be absolute.
    action :list_directory, :map do
      constraints fields: [
                    path: [type: :string, allow_nil?: false],
                    parent: [type: :string],
                    git: [type: :boolean, allow_nil?: false],
                    # arrays of typed maps are not selectable in ash_typescript 0.18's
                    # field types; the entry shape (name, path, git) is typed client-side
                    entries: [type: {:array, :map}, allow_nil?: false],
                    roots: [type: {:array, :map}, allow_nil?: false]
                  ]

      argument :path, :string
      argument :show_hidden, :boolean, default: false

      run fn input, _ ->
        Longx.System.Directory.list(input.arguments[:path],
          show_hidden: input.arguments.show_hidden
        )
      end
    end

    # The picker's "new directory": one segment under an existing parent;
    # answers the entry as the listing would show it
    action :create_directory, :map do
      constraints fields: [
                    name: [type: :string, allow_nil?: false],
                    path: [type: :string, allow_nil?: false],
                    git: [type: :boolean, allow_nil?: false]
                  ]

      argument :parent, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false

      run fn input, _ ->
        Longx.System.Directory.create(input.arguments.parent, input.arguments.name)
      end
    end

    # Longx.Memory — the global memory a settings page edits: the curated
    # index, the notes inbox, a search over both
    action :memory_index, :map do
      constraints fields: [text: [type: :string, allow_nil?: false]]

      run fn _input, _ ->
        # the first look seeds the directory (a repository with a MEMORY.md)
        with :ok <- Longx.Memory.ensure(), do: {:ok, %{text: Longx.Memory.index()}}
      end
    end

    action :memory_write_index do
      argument :text, :string, allow_nil?: false

      run fn input, _ ->
        case Longx.Memory.write_index(Longx.Memory.dir(), input.arguments.text) do
          :ok -> :ok
          {:error, reason} -> {:error, field: :text, message: inspect(reason)}
        end
      end
    end

    action :memory_notes, {:array, :map} do
      constraints items: [
                    fields: [
                      file: [type: :string, allow_nil?: false],
                      at: [type: :string],
                      project: [type: :string],
                      thread: [type: :string],
                      source: [type: :string],
                      text: [type: :string, allow_nil?: false]
                    ]
                  ]

      run fn _input, _ ->
        {:ok,
         for note <- Longx.Memory.notes() do
           %{note | at: note.at && DateTime.to_iso8601(note.at)}
         end}
      end
    end

    action :memory_search, {:array, :map} do
      constraints items: [
                    fields: [
                      file: [type: :string, allow_nil?: false],
                      line: [type: :integer, allow_nil?: false],
                      text: [type: :string, allow_nil?: false]
                    ]
                  ]

      argument :query, :string, allow_nil?: false
      run fn input, _ -> {:ok, Longx.Memory.search(Longx.Memory.dir(), input.arguments.query)} end
    end

    action :memory_delete_note do
      argument :file, :string, allow_nil?: false

      run fn input, _ ->
        case Longx.Memory.delete_note(Longx.Memory.dir(), input.arguments.file) do
          :ok -> :ok
          {:error, :not_found} -> {:error, field: :file, message: "no such note"}
          {:error, :invalid_path} -> {:error, field: :file, message: "must be notes/<name>.md"}
          {:error, reason} -> {:error, field: :file, message: inspect(reason)}
        end
      end
    end

    # the pipeline's switch and last run
    action :memory_status, :map do
      constraints fields: [
                    auto_extract: [type: :boolean, allow_nil?: false],
                    last_run_at: [type: :string],
                    last_error: [type: :string],
                    pending: [type: :integer, allow_nil?: false],
                    folded: [type: :integer, allow_nil?: false]
                  ]

      run fn _input, _ ->
        st = Longx.Memory.status()
        {:ok, %{st | last_run_at: st.last_run_at && DateTime.to_iso8601(st.last_run_at)}}
      end
    end

    action :memory_set_auto_extract do
      argument :enabled, :boolean, allow_nil?: false

      run fn input, _ ->
        Longx.Memory.set_auto_extract(Longx.Memory.dir(), input.arguments.enabled)
      end
    end

    # one pass of the pipeline, now, in the background (it talks to the model
    # for a while); the page polls memory_status for the outcome
    action :memory_run do
      run fn _input, _ ->
        {:ok, _} =
          Task.Supervisor.start_child(Longx.Codex.TaskSupervisor, fn ->
            Longx.Memory.Worker.run_now()
          end)

        :ok
      end
    end

    # Longx.Codex.Sandbox.report/0 for the UI's banner
    action :sandbox, :map do
      constraints fields: [
                    status: [
                      type: :atom,
                      allow_nil?: false,
                      constraints: [one_of: [:ok, :no_net_isolation, :unavailable]]
                    ],
                    reason: [type: :string],
                    bwrap: [type: :string],
                    gpu: [type: :boolean, allow_nil?: false],
                    # host paths worth letting into the sandbox here (id, label, paths, danger);
                    # arrays of typed maps are untyped in ash_typescript 0.18 → typed client-side
                    presets: [type: {:array, :map}, allow_nil?: false],
                    platform: [
                      type: :atom,
                      allow_nil?: false,
                      constraints: [one_of: [:linux, :darwin, :windows]]
                    ],
                    # the server user's home: the chat shortens sandbox-denied paths under it to ~
                    home: [type: :string],
                    checked_at: [type: :utc_datetime_usec, allow_nil?: false]
                  ]

      run fn _input, _ -> {:ok, sandbox_report(Longx.Codex.Sandbox.report())} end
    end

    # the same report after running the probe again (the settings page's "重新检测")
    action :probe_sandbox, :map do
      constraints fields: [
                    status: [
                      type: :atom,
                      allow_nil?: false,
                      constraints: [one_of: [:ok, :no_net_isolation, :unavailable]]
                    ],
                    reason: [type: :string],
                    bwrap: [type: :string],
                    gpu: [type: :boolean, allow_nil?: false],
                    # host paths worth letting into the sandbox here (id, label, paths, danger);
                    # arrays of typed maps are untyped in ash_typescript 0.18 → typed client-side
                    presets: [type: {:array, :map}, allow_nil?: false],
                    platform: [
                      type: :atom,
                      allow_nil?: false,
                      constraints: [one_of: [:linux, :darwin, :windows]]
                    ],
                    # the server user's home: the chat shortens sandbox-denied paths under it to ~
                    home: [type: :string],
                    checked_at: [type: :utc_datetime_usec, allow_nil?: false]
                  ]

      run fn _input, _ ->
        Longx.Codex.Sandbox.probe()
        {:ok, sandbox_report(Longx.Codex.Sandbox.report())}
      end
    end

    # Longx.Upgrade — the version, the last release check, the stage of an
    # upgrade in progress; one shape for the four actions
    action :upgrade_status, :map do
      constraints fields: @upgrade_fields
      run fn _input, _ -> {:ok, upgrade_status()} end
    end

    action :upgrade_check, :map do
      constraints fields: @upgrade_fields

      run fn _input, _ ->
        # the failure is in the status (error), not an RPC error: the page shows it in place
        _ = Longx.Upgrade.check(force: true)
        {:ok, upgrade_status()}
      end
    end

    action :upgrade_apply, :map do
      constraints fields: @upgrade_fields

      run fn _input, _ ->
        case Longx.Upgrade.apply() do
          {:ok, _} ->
            {:ok, upgrade_status()}

          {:error, message} ->
            # a readable refusal (not an install, nothing newer, no package): on the action itself
            {:error,
             Ash.Error.to_error_class(
               Ash.Error.Changes.InvalidArgument.exception(field: :upgrade, message: message)
             )}
        end
      end
    end

    # the GitHub token for the release check (blank removes it); never read back
    # Settings → 工具: the built-in browser (obscura) — whether it may fetch
    # private / loopback addresses. Off is the SSRF guard; on is needed on a
    # fake-ip network (a VPN resolving every site to a private address),
    # since obscura has no per-range allowance
    action :browser_settings, :map do
      constraints fields: @browser_fields
      run fn _input, _ -> {:ok, browser_settings()} end
    end

    action :set_browser_private_network, :map do
      constraints fields: @browser_fields
      argument :enabled, :boolean, allow_nil?: false

      run fn input, _ ->
        :ok = Longx.Browser.set_allow_private_network(input.arguments.enabled)
        {:ok, browser_settings()}
      end
    end

    # Settings → 请求记录: the gateway's last requests (Longx.AI.Gateway.Log) —
    # what codex asked the provider for, newest first; entries are untyped
    # maps (arrays of typed maps are not selectable in ash_typescript 0.18)
    action :gateway_requests, :map do
      constraints fields: [
                    requests: [type: {:array, :map}, allow_nil?: false],
                    keep: [type: :integer, allow_nil?: false]
                  ]

      argument :limit, :integer, default: 100

      run fn input, _ ->
        {:ok,
         %{
           requests: Longx.AI.Gateway.Log.recent(input.arguments.limit) |> Enum.map(&camelize/1),
           keep: Longx.AI.Gateway.Log.keep()
         }}
      end
    end

    action :set_github_token, :map do
      constraints fields: @upgrade_fields
      argument :token, :string

      run fn input, _ ->
        case Longx.Upgrade.set_github_token(input.arguments[:token]) do
          :ok -> {:ok, upgrade_status()}
          {:error, reason} -> {:error, field: :token, message: inspect(reason)}
        end
      end
    end
  end

  defp browser_settings do
    %{
      allow_private_network: Longx.Browser.allow_private_network?(),
      available: Longx.Browser.available?()
    }
  end

  defp upgrade_status do
    st = Longx.Upgrade.status()
    check = st.check || %{}

    %{
      current: Longx.Upgrade.current_version(),
      installed: st.installed,
      latest: check[:latest],
      available: check[:available] || false,
      notes_url: check[:notes_url],
      checked_at: check[:checked_at] && DateTime.to_iso8601(check.checked_at),
      error: st.error,
      stage: st.stage,
      message: st.message,
      target: st.target,
      progress: st.progress,
      has_github_token: st.github_token?
    }
  end

  defp sandbox_report(report),
    do: %{
      status: report.status,
      reason: reason(report.reason),
      bwrap: report.bwrap,
      gpu: report.gpu,
      presets: Longx.Codex.Sandbox.presets(),
      platform: report.platform,
      home: System.user_home(),
      checked_at: report.checked_at
    }

  defp reason(nil), do: nil
  defp reason({kind, message}), do: "#{kind}: #{message}"
  defp reason(other), do: to_string(other)

  defp camelize(map) do
    Map.new(map, fn {key, value} ->
      <<first, rest::binary>> = key |> Atom.to_string() |> Macro.camelize()

      {<<String.downcase(<<first>>)::binary, rest::binary>>,
       if(is_map(value), do: camelize(value), else: value)}
    end)
  end
end
