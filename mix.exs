defmodule Longx.MixProject do
  use Mix.Project

  def project do
    [
      app: :longx,
      version: "0.2.44",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers() ++ [:shim],
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev,
      usage_rules: usage_rules(),
      releases: [longx: [steps: [:assemble, &trim_priv/1, &prune_old_versions/1]]],
      # `mix dialyzer`: mix tasks and test support are part of the app
      dialyzer: [plt_add_apps: [:mix, :ex_unit], plt_file: {:no_warn, "priv/plts/project.plt"}]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Longx.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  # drop the dialyzer PLT from the release — it has no place there (nothing
  # else is bundled: the browser is downloaded on first use into the data dir)
  defp trim_priv(release) do
    priv = Path.join([release.path, "lib", "longx-#{release.version}", "priv"])
    File.rm_rf!(Path.join(priv, "plts"))
    release
  end

  # `mix release --overwrite` replaces only the current version's directory:
  # a cached `_build/prod/rel` (CI caches `_build`) kept `lib/longx-0.1.0/`
  # — with the then-bundled codex, obscura and git, 500 MB — in every
  # tarball up to 0.2.1. Nothing in the release refers to another version.
  defp prune_old_versions(release) do
    lib = Path.join(release.path, "lib")

    for dir <- Path.wildcard(Path.join(lib, "longx-*")),
        Path.basename(dir) != "longx-#{release.version}" do
      File.rm_rf!(dir)
    end

    release
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:ash_typescript, "~> 0.18"},
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:ash_sqlite, "~> 0.2"},
      {:ash_phoenix, "~> 2.0"},
      {:ash, "~> 3.0"},
      {:ash_cloak, "~> 0.4"},
      {:oban, "~> 2.24"},
      # error reporting, on when a DSN is set in the settings (Longx.Sentry)
      {:sentry, "~> 13.5"},
      {:cloak, "~> 1.1"},
      {:ex_json_schema, "~> 0.11"},
      {:bypass, "~> 2.1", only: :test},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:phoenix, "~> 1.8.13"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: [
        "deps.get",
        "ecto.setup",
        "assets.setup",
        "assets.build"
      ],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"],
      "assets.setup": ["cmd --cd assets npm install"],
      "assets.build": ["compile", "ash_typescript.codegen", "cmd --cd assets npm run build"],
      "assets.deploy": ["assets.build"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "cmd --cd native/shim gofmt -l .",
        "cmd --cd native/shim go vet ./...",
        "cmd --cd native/shim go test ./...",
        "ash_typescript.codegen --check",
        "cmd --cd assets npm run present-schema -- --check",
        "cmd --cd assets npm run check",
        "test"
      ],
      "ash.setup": ["ash.setup", "run priv/repo/seeds.exs"]
    ]
  end

  defp usage_rules do
    # Example for those using claude.
    [
      file: "CLAUDE.md",
      # rules to include directly in CLAUDE.md
      usage_rules: ["usage_rules:all"],
      skills: [
        location: ".claude/skills",
        # build skills that combine multiple usage rules
        build: [
          "ash-framework": [
            # The description tells people how to use this skill.
            description:
              "Use this skill working with Ash Framework or any of its extensions. Always consult this when making any domain changes, features or fixes.",
            # Include all Ash dependencies
            usage_rules: [:ash, ~r/^ash_/]
          ],
          "phoenix-framework": [
            description:
              "Use this skill working with Phoenix Framework. Consult this when working with the web layer, controllers, views, liveviews etc.",
            # Include all Phoenix dependencies
            usage_rules: [:phoenix, ~r/^phoenix_/]
          ]
        ]
      ]
    ]
  end
end
