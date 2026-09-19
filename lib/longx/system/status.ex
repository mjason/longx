defmodule Longx.System.Status do
  @moduledoc "A resource without data: generic actions reporting on this node."

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.System,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name "SystemStatus"
  end

  @dependency_fields [
    os: [type: :string, allow_nil?: false],
    missing: [type: :integer, allow_nil?: false],
    install_command: [type: :string],
    # untyped: an array of typed maps cannot be selected into by ash_typescript 0.18
    tools: [type: {:array, :map}, allow_nil?: false],
    checked_at: [type: :string, allow_nil?: false]
  ]

  @browser_fields [
    allow_private_network: [type: :boolean, allow_nil?: false],
    available: [type: :boolean, allow_nil?: false]
  ]

  @browser_status_fields [
    stage: [type: :string, allow_nil?: false],
    received: [type: :integer, allow_nil?: false],
    total: [type: :integer],
    error: [type: :string],
    version: [type: :string, allow_nil?: false],
    latest: [type: :string, allow_nil?: false],
    target: [type: :string],
    path: [type: :string],
    # where the binary in use comes from: env | downloaded (nil: none)
    source: [type: :string],
    installed_version: [type: :string],
    upgradable: [type: :boolean, allow_nil?: false]
  ]

  @upgrade_fields [
    current: [type: :string, allow_nil?: false],
    installed: [type: :boolean, allow_nil?: false],
    # the Docker image: an upgrade is a new image, the page says so
    container: [type: :boolean, allow_nil?: false],
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
    child_effort: [type: :string]
  ]

  @sentry_fields [
    enabled: [type: :boolean, allow_nil?: false],
    dsn: [type: :string],
    environment: [type: :string, allow_nil?: false],
    release: [type: :string, allow_nil?: false]
  ]

  actions do
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

    # the native kernel's settings (Longx.Agent.Definition.Settings): the global layer
    action :agent_settings, :map do
      constraints fields: @agent_settings_fields

      run fn _input, _ -> {:ok, Longx.Agent.Definition.Settings.global()} end
    end

    action :set_agent_settings, :map do
      constraints fields: @agent_settings_fields
      argument :max_depth, :integer
      argument :max_children, :integer
      argument :idle_minutes, :integer
      argument :child_model, :string
      argument :child_effort, :string

      run fn input, _ ->
        # an argument absent stays as it was; one given as null clears it
        given = Map.take(input.arguments, Longx.Agent.Definition.Settings.fields())

        case Longx.Agent.Definition.Settings.put_global(given) do
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

    # the command-line tools the agent leans on: what is missing and how to install it
    action :dependencies, :map do
      constraints fields: @dependency_fields
      run fn _input, _ -> {:ok, dependency_report(Longx.System.Dependencies.report())} end
    end

    action :check_dependencies, :map do
      constraints fields: @dependency_fields

      run fn _input, _ ->
        {:ok, dependency_report(Longx.System.Dependencies.report(force: true))}
      end
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

    # error reporting (Longx.Sentry): on when a DSN is saved
    action :sentry_status, :map do
      constraints fields: @sentry_fields
      run fn _input, _ -> {:ok, Longx.Sentry.status()} end
    end

    action :set_sentry_dsn, :map do
      constraints fields: @sentry_fields
      argument :dsn, :string, allow_nil?: false, constraints: [allow_empty?: true]

      run fn input, _ ->
        case Longx.Sentry.set_dsn(input.arguments.dsn) do
          {:ok, _} -> {:ok, Longx.Sentry.status()}
          {:error, message} -> argument_error(:dsn, message)
        end
      end
    end

    action :sentry_test, :map do
      constraints fields: [
                    ok: [type: :boolean, allow_nil?: false],
                    message: [type: :string, allow_nil?: false]
                  ]

      run fn _input, _ ->
        case Longx.Sentry.send_test() do
          {:ok, id} -> {:ok, %{ok: true, message: id}}
          {:error, message} -> {:ok, %{ok: false, message: message}}
        end
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

    # the headless browser's download (Longx.Browser.Installer): installed, downloading (bytes), failed
    action :browser_status, :map do
      constraints fields: @browser_status_fields
      run fn _input, _ -> {:ok, browser_status()} end
    end

    action :browser_install, :map do
      constraints fields: @browser_status_fields

      run fn _input, _ ->
        case Longx.Browser.Installer.install() do
          :ok ->
            {:ok, browser_status()}

          {:error, :unsupported_platform} ->
            argument_error(:platform, "obscura has no build for this platform")
        end
      end
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
    # what went wrong on the server lately (Longx.System.Faults), newest first
    action :recent_faults, :map do
      constraints fields: [
                    faults: [type: {:array, :map}, allow_nil?: false],
                    recent: [type: :integer, allow_nil?: false]
                  ]

      run fn _input, _ ->
        {:ok,
         %{
           faults:
             Longx.System.Faults.recent()
             |> Enum.map(fn f ->
               %{
                 "kind" => Atom.to_string(f.kind),
                 "where" => f.where,
                 "detail" => f.detail,
                 "at" => DateTime.to_iso8601(f.at)
               }
             end),
           recent:
             Longx.System.Faults.count_since(DateTime.add(DateTime.utc_now(), -3600, :second))
         }}
      end
    end

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

  defp browser_status do
    st = Longx.Browser.Installer.status()
    %{st | stage: Atom.to_string(st.stage), source: st.source && Atom.to_string(st.source)}
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
      container: st.container,
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

  defp camelize(map) do
    Map.new(map, fn {key, value} ->
      <<first, rest::binary>> = key |> Atom.to_string() |> Macro.camelize()

      {<<String.downcase(<<first>>)::binary, rest::binary>>,
       if(is_map(value), do: camelize(value), else: value)}
    end)
  end

  defp dependency_report(report) do
    %{
      os: report.os,
      missing: report.missing,
      install_command: report.install_command,
      checked_at: DateTime.to_iso8601(report.checked_at),
      tools:
        Enum.map(report.tools, fn tool ->
          %{
            "name" => tool.name,
            "command" => tool.command,
            "found" => tool.found,
            "path" => tool.path,
            "version" => tool.version,
            "install" => %{
              "apt" => tool.install.apt,
              "brew" => tool.install.brew,
              "winget" => tool.install.winget
            }
          }
        end)
    }
  end

  defp argument_error(field, message) do
    {:error,
     Ash.Error.Invalid.exception(
       errors: [%Ash.Error.Changes.InvalidArgument{field: field, message: message}]
     )}
  end
end
