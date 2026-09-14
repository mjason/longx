defmodule Longx.MixProject do
  use Mix.Project

  def project do
    [
      app: :longx,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers() ++ [:shim],
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev,
      usage_rules: usage_rules(),
      releases: [longx: [steps: [:assemble, &bundles/1]]],
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
  # `mix release` copies priv following symlinks, which turns the bundled git
  # (145 builtins linking to one binary) into 700 MB. Recopy the bundles with
  # their links, and drop the dialyzer PLT — it has no place in a release.
  defp bundles(release) do
    priv = Path.join([release.path, "lib", "longx-#{release.version}", "priv"])
    File.rm_rf!(Path.join(priv, "plts"))

    for dir <- ~w(codex git obscura), src = Path.join("priv", dir), File.dir?(src) do
      dst = Path.join(priv, dir)
      File.rm_rf!(dst)
      copy_tree(src, dst)
    end

    release
  end

  defp copy_tree(src, dst) do
    case File.lstat!(src).type do
      :symlink ->
        File.ln_s!(File.read_link!(src), dst)

      :directory ->
        File.mkdir_p!(dst)
        for name <- File.ls!(src), do: copy_tree(Path.join(src, name), Path.join(dst, name))

      _ ->
        File.cp!(src, dst)
    end
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
        "assets.build",
        "codex.fetch",
        "git.fetch",
        "obscura.fetch"
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
