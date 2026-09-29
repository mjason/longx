defmodule Longx.System.Types do
  @moduledoc """
  The typed results of the Longx.System actions the page reads, as Ash map
  types with a GraphQL name: only a `NewType` with `graphql_type/1` is an
  object type to AshGraphql (an inline `:map` with `fields` is a `Json`
  scalar); nested `fields` are typed with it, named `<type>_<field>`.
  """

  defmodule ListDirectory do
    @moduledoc "the result of `Longx.System.Status.list_directory`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          path: [type: :string, allow_nil?: false],
          parent: [type: :string],
          git: [type: :boolean, allow_nil?: false],
          # untyped: a Json value on the wire, its keys camelCased by the client
          # field types; the entry shape (name, path, git) is typed client-side
          entries: [type: {:array, :map}, allow_nil?: false],
          roots: [type: {:array, :map}, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :list_directory
  end

  defmodule CreateDirectory do
    @moduledoc "the result of `Longx.System.Status.create_directory`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          name: [type: :string, allow_nil?: false],
          path: [type: :string, allow_nil?: false],
          git: [type: :boolean, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :create_directory
  end

  defmodule KnowledgeDoc do
    @moduledoc "`Longx.System.Status.knowledge_docs` and other actions returning `@knowledge_doc_fields`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          root: [type: :string, allow_nil?: false],
          path: [type: :string, allow_nil?: false],
          title: [type: :string, allow_nil?: false],
          summary: [type: :string, allow_nil?: false],
          tags: [type: {:array, :string}, allow_nil?: false],
          always: [type: :boolean, allow_nil?: false],
          writable: [type: :boolean, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :knowledge_doc
  end

  defmodule KnowledgeRead do
    @moduledoc "the result of `Longx.System.Status.knowledge_read`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          text: [
            type: :string,
            allow_nil?: false,
            constraints: [trim?: false, allow_empty?: true]
          ]
        ]
      ]

    def graphql_type(_), do: :knowledge_read
  end

  defmodule AgentSettings do
    @moduledoc "`Longx.System.Status.agent_settings` and other actions returning `@agent_settings_fields`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          max_depth: [type: :integer, allow_nil?: false],
          max_children: [type: :integer, allow_nil?: false],
          idle_minutes: [type: :integer, allow_nil?: false],
          model_retries: [type: :integer, allow_nil?: false],
          command_oom_priority: [type: :integer, allow_nil?: false],
          memory_floor_percent: [type: :integer, allow_nil?: false],
          command_shell: [type: :string, allow_nil?: false],
          child_model: [type: :string],
          child_effort: [type: :string]
        ]
      ]

    def graphql_type(_), do: :agent_settings
  end

  defmodule Dependency do
    @moduledoc "`Longx.System.Status.dependencies` and other actions returning `@dependency_fields`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          os: [type: :string, allow_nil?: false],
          missing: [type: :integer, allow_nil?: false],
          install_command: [type: :string],
          # untyped: a Json value on the wire, its keys camelCased by the client
          tools: [type: {:array, :map}, allow_nil?: false],
          checked_at: [type: :string, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :dependency
  end

  defmodule PublicUrl do
    @moduledoc "the result of `Longx.System.Status.public_url`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          url: [type: :string, allow_nil?: false],
          setting: [type: :string]
        ]
      ]

    def graphql_type(_), do: :public_url
  end

  defmodule FileRules do
    @moduledoc "`Longx.System.Status.file_rules` and other actions returning `@file_rules_fields`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          ignore: [
            type: :string,
            allow_nil?: false,
            constraints: [allow_empty?: true, trim?: false]
          ],
          watch: [
            type: :string,
            allow_nil?: false,
            constraints: [allow_empty?: true, trim?: false]
          ],
          builtin_ignore: [type: {:array, :string}, allow_nil?: false],
          builtin_watch: [type: {:array, :string}, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :file_rules
  end

  defmodule Sentry do
    @moduledoc "`Longx.System.Status.sentry_status` and other actions returning `@sentry_fields`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          enabled: [type: :boolean, allow_nil?: false],
          dsn: [type: :string],
          environment: [type: :string, allow_nil?: false],
          release: [type: :string, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :sentry
  end

  defmodule SentryTest do
    @moduledoc "the result of `Longx.System.Status.sentry_test`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          ok: [type: :boolean, allow_nil?: false],
          message: [type: :string, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :sentry_test
  end

  defmodule SetPublicUrl do
    @moduledoc "the result of `Longx.System.Status.set_public_url`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          url: [type: :string, allow_nil?: false],
          setting: [type: :string]
        ]
      ]

    def graphql_type(_), do: :set_public_url
  end

  defmodule Upgrade do
    @moduledoc "`Longx.System.Status.upgrade_status` and other actions returning `@upgrade_fields`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
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
              one_of: [
                :idle,
                :downloading,
                :verifying,
                :installing,
                :restarting,
                :installed,
                :failed
              ]
            ]
          ],
          message: [type: :string],
          target: [type: :string],
          # the tarball's bytes so far while downloading (total nil without a content-length)
          progress: [type: :map],
          has_github_token: [type: :boolean, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :upgrade
  end

  defmodule Browser do
    @moduledoc "`Longx.System.Status.browser_settings` and other actions returning `@browser_fields`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          allow_private_network: [type: :boolean, allow_nil?: false],
          available: [type: :boolean, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :browser
  end

  defmodule BrowserStatus do
    @moduledoc "`Longx.System.Status.browser_status` and other actions returning `@browser_status_fields`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
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
      ]

    def graphql_type(_), do: :browser_status
  end

  defmodule RunningCommands do
    @moduledoc "the result of `Longx.System.Status.running_commands`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [fields: [commands: [type: {:array, :map}, allow_nil?: false]]]

    def graphql_type(_), do: :running_commands
  end

  defmodule KillCommand do
    @moduledoc "the result of `Longx.System.Status.kill_command`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [fields: [ok: [type: :boolean, allow_nil?: false]]]

    def graphql_type(_), do: :kill_command
  end

  defmodule RecentFaults do
    @moduledoc "the result of `Longx.System.Status.recent_faults`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          faults: [type: {:array, :map}, allow_nil?: false],
          recent: [type: :integer, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :recent_faults
  end

  defmodule GatewayRequests do
    @moduledoc "the result of `Longx.System.Status.gateway_requests`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          requests: [type: {:array, :map}, allow_nil?: false],
          keep: [type: :integer, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :gateway_requests
  end

  defmodule TlsVariable do
    @moduledoc """
    One of the DNS provider's variables as the page sends it: a value, `""`
    to keep the stored one, nil to remove it (`Longx.Tls.save/1`).
    """
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          name: [type: :string, allow_nil?: false],
          # "" is not nil here: it keeps the stored value
          value: [type: :string, constraints: [allow_empty?: true, trim?: false]]
        ]
      ]

    def graphql_type(_), do: :tls_variable
    def graphql_input_type(_), do: :tls_variable_input
  end

  defmodule TlsCertificate do
    @moduledoc "the certificate on disk (`Longx.Tls.certificate/0`)"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          domains: [type: {:array, :string}, allow_nil?: false, constraints: [nil_items?: false]],
          not_before: [type: :utc_datetime],
          not_after: [type: :utc_datetime],
          serial: [type: :string],
          issued_at: [type: :utc_datetime]
        ]
      ]

    def graphql_type(_), do: :tls_certificate
  end

  defmodule TlsResolution do
    @moduledoc """
    where a name points: the public resolvers' answer and whether that is
    this machine, this machine's own answer and whether that is a proxy's
    fake-ip address
    """
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          domain: [type: :string, allow_nil?: false],
          addresses: [
            type: {:array, :string},
            allow_nil?: false,
            constraints: [nil_items?: false]
          ],
          here: [type: :boolean, allow_nil?: false],
          local: [type: {:array, :string}, allow_nil?: false, constraints: [nil_items?: false]],
          fake_ip: [type: :boolean, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :tls_resolution
  end

  defmodule TlsResolutionReport do
    @moduledoc "the result of `Longx.System.Status.tls_resolution` (`Longx.Tls.resolution_report/1`)"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          addresses: [
            type: {:array, :string},
            allow_nil?: false,
            constraints: [nil_items?: false]
          ],
          resolution: [
            type: {:array, TlsResolution},
            allow_nil?: false,
            constraints: [nil_items?: false]
          ],
          # this machine's DNS answers with a proxy's addresses
          fake_ip: [type: :boolean, allow_nil?: false],
          # the resolvers the TXT check would use now ([] = this machine's)
          check_resolvers: [
            type: {:array, :string},
            allow_nil?: false,
            constraints: [nil_items?: false]
          ]
        ]
      ]

    def graphql_type(_), do: :tls_resolution_report
  end

  defmodule TlsStatus do
    @moduledoc "`Longx.System.Status.tls_status` and the HTTPS actions (`Longx.Tls.report/0`)"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          enabled: [type: :boolean, allow_nil?: false],
          domains: [type: {:array, :string}, allow_nil?: false, constraints: [nil_items?: false]],
          provider: [type: :string],
          email: [type: :string, allow_nil?: false, constraints: [allow_empty?: true]],
          directory: [type: :string, allow_nil?: false],
          port: [type: :integer, allow_nil?: false],
          redirect: [type: :boolean, allow_nil?: false],
          resolvers: [
            type: {:array, :string},
            allow_nil?: false,
            constraints: [nil_items?: false]
          ],
          propagation_check: [type: :boolean, allow_nil?: false],
          propagation_wait: [type: :integer, allow_nil?: false],
          http_port: [type: :integer],
          # the provider's variables that have a value — never the values
          env_set: [type: {:array, :string}, allow_nil?: false, constraints: [nil_items?: false]],
          # the issuance: idle | downloading | verifying | extracting | issuing | failed
          stage: [type: :string, allow_nil?: false],
          received: [type: :integer, allow_nil?: false],
          total: [type: :integer],
          error: [type: :string],
          started_at: [type: :utc_datetime],
          finished_at: [type: :utc_datetime],
          certificate: [type: TlsCertificate],
          # HTTPS served now, and where
          serving: [type: :boolean, allow_nil?: false],
          url: [type: :string],
          # this machine's addresses (the A record to add)
          addresses: [
            type: {:array, :string},
            allow_nil?: false,
            constraints: [nil_items?: false]
          ],
          tool_version: [type: :string, allow_nil?: false],
          tool_installed: [type: :boolean, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :tls_status
  end

  defmodule TlsProviderVariable do
    @moduledoc "an environment variable a DNS provider reads, with lego's description"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          name: [type: :string, allow_nil?: false],
          description: [type: :string, constraints: [allow_empty?: true]]
        ]
      ]

    def graphql_type(_), do: :tls_provider_variable
  end

  defmodule TlsProvider do
    @moduledoc "one of lego's DNS providers (`Longx.Tls.providers/0`)"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          code: [type: :string, allow_nil?: false],
          name: [type: :string, allow_nil?: false],
          url: [type: :string],
          aliases: [type: {:array, :string}, allow_nil?: false, constraints: [nil_items?: false]],
          credentials: [
            type: {:array, TlsProviderVariable},
            allow_nil?: false,
            constraints: [nil_items?: false]
          ],
          additional: [
            type: {:array, TlsProviderVariable},
            allow_nil?: false,
            constraints: [nil_items?: false]
          ]
        ]
      ]

    def graphql_type(_), do: :tls_provider
  end

  defmodule TlsProviders do
    @moduledoc "the result of `Longx.System.Status.tls_providers`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          providers: [
            type: {:array, TlsProvider},
            allow_nil?: false,
            constraints: [nil_items?: false]
          ]
        ]
      ]

    def graphql_type(_), do: :tls_providers
  end
end
