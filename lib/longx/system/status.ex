defmodule Longx.System.Status do
  @moduledoc "A resource without data: generic actions reporting on this node."

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.System,
    extensions: [AshGraphql.Resource]

  alias Longx.System.Types

  # no rows, no object type: only its generic actions are in the schema
  graphql do
    generate_object? false
  end

  actions do
    # The directory picker: subdirectories of `path` (home when omitted),
    # each flagged when it is a git repository. Files are never listed;
    # dot-directories only with `show_hidden`. Paths must be absolute.
    action :list_directory, Types.ListDirectory do
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
    action :create_directory, Types.CreateDirectory do
      argument :parent, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false

      run fn input, _ ->
        Longx.System.Directory.create(input.arguments.parent, input.arguments.name)
      end
    end

    action :knowledge_docs, {:array, Types.KnowledgeDoc} do
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

    action :knowledge_read, Types.KnowledgeRead do
      # a file's text, as it is: Ash trims strings unless told not to

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
    action :agent_settings, Types.AgentSettings do
      run fn _input, _ -> {:ok, Longx.Agent.Definition.Settings.for_settings_page()} end
    end

    action :command_guard_status, Types.CommandGuardStatus do
      argument :project_id, :uuid

      run fn input, _ ->
        settings =
          case input.arguments[:project_id] do
            nil ->
              {:ok, Longx.Agent.Definition.Settings.global()}

            id ->
              case Ash.get(Longx.Projects.Project, id) do
                {:ok, project} -> {:ok, Longx.Agent.Definition.Settings.for_project(project)}
                {:error, _} -> argument_error(:project_id, "project not found")
              end
          end

        with {:ok, settings} <- settings,
             do: {:ok, Longx.System.CommandGuard.report(settings)}
      end
    end

    action :set_agent_settings, Types.AgentSettings do
      argument :max_depth, :integer
      argument :max_children, :integer
      argument :idle_minutes, :integer
      argument :model_retries, :integer
      argument :command_oom_priority, :integer
      argument :memory_floor_percent, :integer
      argument :command_cgroup_mode, :string
      argument :command_memory_limit_percent, :integer
      argument :command_swap_limit_mb, :integer
      argument :command_shell, :string
      argument :extra_path, :string, constraints: [allow_empty?: true, trim?: false]
      argument :child_model, :string
      argument :child_effort, :string

      run fn input, _ ->
        # an argument absent stays as it was; one given as null clears it
        given = Map.take(input.arguments, Longx.Agent.Definition.Settings.fields())

        case Longx.Agent.Definition.Settings.put_global(given) do
          {:ok, settings} ->
            {:ok,
             Map.put(
               settings,
               :default_extra_path,
               Longx.Agent.Definition.Settings.defaults().extra_path
             )}

          {:error, %{field: field, message: message}} ->
            {:error,
             Ash.Error.Invalid.exception(
               errors: [%Ash.Error.Changes.InvalidArgument{field: field, message: message}]
             )}
        end
      end
    end

    # the command-line tools the agent leans on: what is missing and how to install it
    action :dependencies, Types.Dependency do
      run fn _input, _ -> {:ok, dependency_report(Longx.System.Dependencies.report())} end
    end

    action :check_dependencies, Types.Dependency do
      run fn _input, _ ->
        {:ok, dependency_report(Longx.System.Dependencies.report(force: true))}
      end
    end

    # the address a login sends the person back to (Longx.System.public_url/0)
    action :public_url, Types.PublicUrl do
      run fn _input, _ ->
        {:ok, %{url: Longx.System.public_url(), setting: Longx.System.public_url_setting()}}
      end
    end

    # what Longx ignores in every project (Longx.Projects.FileRules): the global
    # texts, gitignore syntax, beside the built-in lists they stack on
    action :file_rules, Types.FileRules do
      run fn _input, _ -> {:ok, file_rules()} end
    end

    action :set_file_rules, Types.FileRules do
      argument :ignore, :string, constraints: [allow_empty?: true, trim?: false]
      argument :watch, :string, constraints: [allow_empty?: true, trim?: false]

      run fn input, _ ->
        with {:ok, _} <- Longx.Projects.FileRules.put_global(input.arguments),
             do: {:ok, file_rules()}
      end
    end

    # error reporting (Longx.Sentry): on when a DSN is saved
    action :sentry_status, Types.Sentry do
      run fn _input, _ -> {:ok, Longx.Sentry.status()} end
    end

    action :set_sentry_dsn, Types.Sentry do
      argument :dsn, :string, allow_nil?: false, constraints: [allow_empty?: true]

      run fn input, _ ->
        case Longx.Sentry.set_dsn(input.arguments.dsn) do
          {:ok, _} -> {:ok, Longx.Sentry.status()}
          {:error, message} -> argument_error(:dsn, message)
        end
      end
    end

    action :sentry_test, Types.SentryTest do
      run fn _input, _ ->
        case Longx.Sentry.send_test() do
          {:ok, id} -> {:ok, %{ok: true, message: id}}
          {:error, message} -> {:ok, %{ok: false, message: message}}
        end
      end
    end

    action :set_public_url, Types.SetPublicUrl do
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
    action :upgrade_status, Types.Upgrade do
      run fn _input, _ -> {:ok, upgrade_status()} end
    end

    action :upgrade_check, Types.Upgrade do
      run fn _input, _ ->
        # the failure is in the status (error), not an RPC error: the page shows it in place
        _ = Longx.Upgrade.check(force: true)
        {:ok, upgrade_status()}
      end
    end

    action :upgrade_apply, Types.Upgrade do
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
    action :browser_settings, Types.Browser do
      run fn _input, _ -> {:ok, browser_settings()} end
    end

    # the headless browser's download (Longx.Browser.Installer): installed, downloading (bytes), failed
    action :browser_status, Types.BrowserStatus do
      run fn _input, _ -> {:ok, browser_status()} end
    end

    action :browser_install, Types.BrowserStatus do
      run fn _input, _ ->
        case Longx.Browser.Installer.install() do
          :ok ->
            {:ok, browser_status()}

          {:error, :unsupported_platform} ->
            argument_error(:platform, "obscura has no build for this platform")
        end
      end
    end

    # The local desktop driver's download (permissions and MCP are separate).
    action :computer_settings, Types.ComputerSettings do
      argument :id, :string, default: "local", allow_nil?: false
      run fn input, _ -> {:ok, Longx.Computer.Service.settings(input.arguments.id)} end
    end

    action :computer_configure, Types.ComputerSettings do
      argument :id, :string, default: "local", allow_nil?: false
      argument :name, :string, default: "Local", allow_nil?: false
      argument :url, :string, allow_nil?: false

      argument :token, :string,
        sensitive?: true,
        default: "",
        constraints: [allow_empty?: true, trim?: false]

      run fn input, _ ->
        case Longx.Computer.Service.save(
               input.arguments.id,
               input.arguments.name,
               input.arguments.url,
               input.arguments.token
             ) do
          {:ok, settings} ->
            :ok = Longx.Computer.Connection.disconnect(input.arguments.id)
            {:ok, settings}

          {:error, :token_required} ->
            argument_error(
              :token,
              "Enter a service access key (32+ characters); changing the URL requires a new key"
            )

          {:error, :invalid_url} ->
            argument_error(
              :url,
              "Use an http(s) service URL ending in /mcp, without credentials, query or fragment"
            )

          {:error, :duplicate_url} ->
            argument_error(:url, "This computer service URL is already configured")

          {:error, _} ->
            argument_error(:connection, "Could not save the computer service settings")
        end
      end
    end

    action :computer_connection, Types.ComputerConnection do
      argument :id, :string, default: "local", allow_nil?: false
      run fn input, _ -> {:ok, Longx.Computer.Connection.status(input.arguments.id)} end
    end

    action :computer_connect, Types.ComputerConnection do
      argument :id, :string, default: "local", allow_nil?: false
      argument :foreground, :boolean, default: false, allow_nil?: false

      run fn input, _ ->
        case Longx.Computer.Connection.connect(input.arguments.id, input.arguments.foreground) do
          {:ok, status} -> {:ok, status}
          {:error, message} -> argument_error(:connection, message)
        end
      end
    end

    action :computer_disconnect, Types.ComputerConnection do
      argument :id, :string, default: "local", allow_nil?: false

      run fn input, _ ->
        :ok = Longx.Computer.Connection.disconnect(input.arguments.id)
        {:ok, Longx.Computer.Connection.status(input.arguments.id)}
      end
    end

    action :computer_devices, {:array, Types.ComputerDevice} do
      run fn _, _ ->
        with {:ok, devices} <- Longx.Computer.Service.list() do
          {:ok,
           Enum.map(devices, &Map.put(&1, :connection, Longx.Computer.Connection.status(&1.id)))}
        end
      end
    end

    action :computer_aliases, Types.ComputerAliases do
      run fn _, _ -> Longx.Computer.Service.aliases() end
    end

    action :computer_delete do
      argument :id, :string, allow_nil?: false

      run fn input, _ ->
        :ok = Longx.Computer.Connection.stop(input.arguments.id)
        Longx.Computer.Service.delete(input.arguments.id)
      end
    end

    action :computer_set_alias, Types.ComputerAliases do
      argument :name, :string, allow_nil?: false
      argument :computers, {:array, :string}, allow_nil?: false

      run fn input, _ ->
        case Longx.Computer.Service.put_alias(input.arguments.name, input.arguments.computers) do
          :ok ->
            Longx.Computer.Service.aliases()

          {:error, _} ->
            argument_error(
              :computers,
              "Use a valid alias name and an ordered, nonempty list of known computers without duplicates"
            )
        end
      end
    end

    action :computer_delete_alias, Types.ComputerAliases do
      argument :name, :string, allow_nil?: false

      run fn input, _ ->
        with :ok <- Longx.Computer.Service.delete_alias(input.arguments.name),
             do: Longx.Computer.Service.aliases()
      end
    end

    action :computer_set_default, Types.ComputerAliases do
      argument :name, :string

      run fn input, _ ->
        case Longx.Computer.Service.set_default(input.arguments.name) do
          :ok -> Longx.Computer.Service.aliases()
          {:error, _} -> argument_error(:name, "Select an existing computer alias")
        end
      end
    end

    # HTTPS with a certificate longx-cert obtains through DNS-01 (Longx.Tls)
    action :tls_status, Types.TlsStatus do
      run fn _input, _ -> {:ok, Longx.Tls.report()} end
    end

    action :tls_providers, Types.TlsProviders do
      run fn _input, _ -> {:ok, %{providers: Longx.Tls.providers()}} end
    end

    # where the names point as the world sees them (public DNS, not a proxy's
    # fake-ip), this machine's answer beside it; the names as typed, unsaved
    action :tls_resolution, Types.TlsResolutionReport do
      argument :domains, {:array, :string}, allow_nil?: false
      run fn input, _ -> {:ok, Longx.Tls.resolution_report(input.arguments.domains)} end
    end

    # saves what is given (the variables: a value, "" to keep, nil to remove)
    # and brings the listener in line — off stops it, another port moves it
    action :set_tls, Types.TlsStatus do
      argument :enabled, :boolean
      argument :domains, {:array, :string}
      argument :provider, :string
      argument :email, :string, constraints: [allow_empty?: true]
      argument :directory, :string
      argument :port, :integer
      argument :redirect, :boolean
      argument :resolvers, {:array, :string}
      argument :propagation_check, :boolean
      argument :propagation_wait, :integer
      argument :env, {:array, Types.TlsVariable}

      run fn input, _ ->
        attrs =
          input.arguments
          |> Map.take([
            :enabled,
            :domains,
            :provider,
            :email,
            :directory,
            :port,
            :redirect,
            :resolvers,
            :propagation_check,
            :propagation_wait
          ])
          |> Map.put(:env, Map.new(input.arguments[:env] || [], &{&1.name, &1[:value]}))

        case Longx.Tls.save(attrs) do
          {:ok, _} ->
            :ok = Longx.Tls.Manager.apply_settings()
            {:ok, Longx.Tls.report()}

          {:error, field, message} ->
            argument_error(field, message)
        end
      end
    end

    # obtains the certificate now (downloading longx-cert first when needed);
    # the page follows the stage through tls_status
    action :tls_issue, Types.TlsStatus do
      run fn _input, _ ->
        case Longx.Tls.Manager.issue(:manual) do
          :ok ->
            {:ok, Longx.Tls.report()}

          {:error, :not_configured} ->
            argument_error(:domains, "save the names and a DNS provider first")
        end
      end
    end

    action :tls_disable, Types.TlsStatus do
      run fn _input, _ ->
        {:ok, _} = Longx.Tls.save(%{enabled: false})
        :ok = Longx.Tls.Manager.apply_settings()
        {:ok, Longx.Tls.report()}
      end
    end

    action :set_browser_private_network, Types.Browser do
      argument :enabled, :boolean, allow_nil?: false

      run fn input, _ ->
        :ok = Longx.Browser.set_allow_private_network(input.arguments.enabled)
        {:ok, browser_settings()}
      end
    end

    # Settings → 请求记录: the gateway's last requests (Longx.AI.Gateway.Log) —
    # what went wrong on the server lately (Longx.System.Faults), newest first
    # the agents' live commands, for the settings page; one killed from there
    action :running_commands, Types.RunningCommands do
      run fn _input, _ ->
        {:ok,
         %{
           commands:
             Enum.map(Longx.System.Commands.list(), fn c ->
               # an untyped map crosses the wire as it is: the client's names here
               %{
                 "id" => c.id,
                 "cmd" => c.cmd,
                 "osPid" => c.os_pid,
                 "threadId" => c.thread_id,
                 "startedAt" => c.started_at,
                 "elapsedMs" => c.elapsed_ms,
                 "session" =>
                   case c.session do
                     nil ->
                       nil

                     s ->
                       %{
                         "title" => s.title,
                         "slug" => s.slug,
                         "threadRowId" => s.thread_row_id,
                         "rootRowId" => s.root_row_id,
                         "agent" => s.agent
                       }
                   end
               }
             end)
         }}
      end
    end

    action :kill_command, Types.KillCommand do
      argument :id, :string, allow_nil?: false

      run fn input, _ ->
        case Longx.System.Commands.kill(input.arguments.id) do
          :ok -> {:ok, %{ok: true}}
          {:error, :not_found} -> argument_error(:id, "no such command is running")
        end
      end
    end

    action :recent_faults, Types.RecentFaults do
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
    # maps (untyped: a Json value on the wire, its keys camelCased by the client)
    action :gateway_requests, Types.GatewayRequests do
      argument :limit, :integer, default: 100

      run fn input, _ ->
        {:ok,
         %{
           requests: Longx.AI.Gateway.Log.recent(input.arguments.limit) |> Enum.map(&camelize/1),
           keep: Longx.AI.Gateway.Log.keep()
         }}
      end
    end

    action :set_github_token, Types.Upgrade do
      argument :token, :string

      run fn input, _ ->
        case Longx.Upgrade.set_github_token(input.arguments[:token]) do
          :ok -> {:ok, upgrade_status()}
          {:error, reason} -> {:error, field: :token, message: inspect(reason)}
        end
      end
    end
  end

  defp file_rules do
    builtin = Longx.Projects.FileRules.builtin()
    global = Longx.Projects.FileRules.global()

    %{
      ignore: global.ignore,
      watch: global.watch,
      builtin_ignore: builtin.ignore,
      builtin_watch: builtin.watch
    }
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
