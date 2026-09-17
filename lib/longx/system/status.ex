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

  @agent_settings_fields [
    max_depth: [type: :integer, allow_nil?: false],
    max_children: [type: :integer, allow_nil?: false],
    idle_minutes: [type: :integer, allow_nil?: false],
    child_model: [type: :string],
    child_effort: [type: :string],
    reviewer_model: [type: :string],
    reviewer_effort: [type: :string]
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
    # the native kernel's knowledge, the shipped root (read-only) and the
    # person's global root: what Settings → 知识 lists and edits
    @knowledge_doc_fields [
      root: [type: :string, allow_nil?: false],
      path: [type: :string, allow_nil?: false],
      title: [type: :string, allow_nil?: false],
      summary: [type: :string, allow_nil?: false],
      tags: [type: {:array, :string}, allow_nil?: false],
      always: [type: :boolean, allow_nil?: false],
      writable: [type: :boolean, allow_nil?: false]
    ]

    action :knowledge_docs, {:array, :map} do
      constraints items: [fields: @knowledge_doc_fields]

      run fn _input, _ ->
        {:ok,
         Enum.map(Longx.Agent.Knowledge.global_docs(), fn doc ->
           %{
             root: Atom.to_string(doc.root),
             path: doc.path,
             title: doc.title,
             summary: doc.summary,
             tags: doc.tags,
             always: doc.always?,
             writable: doc.root != :longx
           }
         end)}
      end
    end

    action :knowledge_read, :map do
      # a file's text, as it is: Ash trims strings unless told not to
      constraints fields: [
                    text: [
                      type: :string,
                      allow_nil?: false,
                      constraints: [trim?: false, allow_empty?: true]
                    ]
                  ]

      argument :path, :string, allow_nil?: false

      run fn input, _ ->
        case Longx.Agent.Knowledge.read_raw(
               Longx.Agent.Knowledge.global_cwd(),
               input.arguments.path
             ) do
          {:ok, text} -> {:ok, %{text: text}}
          {:error, message} -> argument_error(:path, message)
        end
      end
    end

    action :knowledge_write do
      argument :path, :string, allow_nil?: false

      argument :content, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]

      run fn input, _ ->
        case Longx.Agent.Knowledge.write(
               Longx.Agent.Knowledge.global_cwd(),
               input.arguments.path,
               input.arguments.content
             ) do
          {:ok, _file} -> :ok
          {:error, message} -> argument_error(:content, message)
        end
      end
    end

    action :knowledge_delete do
      argument :path, :string, allow_nil?: false

      run fn input, _ ->
        case Longx.Agent.Knowledge.delete(
               Longx.Agent.Knowledge.global_cwd(),
               input.arguments.path
             ) do
          :ok -> :ok
          {:error, message} -> argument_error(:path, message)
        end
      end
    end

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
    # the native kernel's settings (Longx.Agent.Settings): the global layer
    action :agent_settings, :map do
      constraints fields: @agent_settings_fields

      run fn _input, _ -> {:ok, Longx.Agent.Settings.global()} end
    end

    action :set_agent_settings, :map do
      constraints fields: @agent_settings_fields
      argument :max_depth, :integer
      argument :max_children, :integer
      argument :idle_minutes, :integer
      argument :child_model, :string
      argument :child_effort, :string
      argument :reviewer_model, :string
      argument :reviewer_effort, :string

      run fn input, _ ->
        # an argument absent stays as it was; one given as null clears it
        given = Map.take(input.arguments, Longx.Agent.Settings.fields())

        case Longx.Agent.Settings.put_global(given) do
          {:ok, settings} ->
            {:ok, settings}

          {:error, %{field: field, message: message}} ->
            {:error,
             Ash.Error.Invalid.exception(
               errors: [%Ash.Error.Changes.InvalidArgument{field: field, message: message}]
             )}
        end
      end
    end

    # the person's global agent files (agent.exs, agents/, plugs/), for the settings page
    action :agent_files, {:array, :map} do
      constraints items: [
                    fields: [
                      path: [type: :string, allow_nil?: false],
                      size: [type: :integer, allow_nil?: false]
                    ]
                  ]

      run fn _input, _ -> {:ok, Longx.Agent.GlobalFiles.list()} end
    end

    action :agent_read_file, :map do
      constraints fields: [
                    text: [
                      type: :string,
                      allow_nil?: false,
                      constraints: [trim?: false, allow_empty?: true]
                    ]
                  ]

      argument :path, :string, allow_nil?: false

      run fn input, _ ->
        with {:ok, text} <- file_result(Longx.Agent.GlobalFiles.read(input.arguments.path)),
             do: {:ok, %{text: text}}
      end
    end

    action :agent_write_file do
      argument :path, :string, allow_nil?: false

      argument :content, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]

      run fn input, _ ->
        file_result(Longx.Agent.GlobalFiles.write(input.arguments.path, input.arguments.content))
      end
    end

    action :agent_delete_file do
      argument :path, :string, allow_nil?: false

      run fn input, _ -> file_result(Longx.Agent.GlobalFiles.delete(input.arguments.path)) end
    end

    # the address a login sends the person back to (Longx.System.public_url/0)
    action :public_url, :map do
      constraints fields: [
                    url: [type: :string, allow_nil?: false],
                    setting: [type: :string]
                  ]

      run fn _input, _ ->
        {:ok, %{url: Longx.System.public_url(), setting: Longx.System.public_url_setting()}}
      end
    end

    action :set_public_url, :map do
      constraints fields: [
                    url: [type: :string, allow_nil?: false],
                    setting: [type: :string]
                  ]

      argument :url, :string, allow_nil?: false, constraints: [allow_empty?: true]

      run fn input, _ ->
        case Longx.System.set_public_url(input.arguments.url) do
          {:ok, _} ->
            {:ok, %{url: Longx.System.public_url(), setting: Longx.System.public_url_setting()}}

          {:error, message} ->
            argument_error(:url, message)
        end
      end
    end

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

  defp file_result(:ok), do: :ok
  defp file_result({:ok, value}), do: {:ok, value}
  defp file_result({:error, message}), do: argument_error(:path, message)

  defp argument_error(field, message) do
    {:error,
     Ash.Error.Invalid.exception(
       errors: [%Ash.Error.Changes.InvalidArgument{field: field, message: message}]
     )}
  end
end
