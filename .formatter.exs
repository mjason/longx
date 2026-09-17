[
  import_deps: [
    :ash_typescript,
    :ash_sqlite,
    :ash_phoenix,
    :ash,
    :reactor,
    :ecto,
    :ecto_sql,
    :phoenix
  ],
  # the agent kernel's declarative surface (Longx.Agent.Plug / Pipeline)
  locals_without_parens: [
    plug: 1,
    plug: 2,
    tool: 2,
    tool: 3,
    tool: 4,
    param: 3,
    param: 4,
    instructions: 1,
    # the agent description (Longx.Agent.Config)
    agent: 1,
    version: 1,
    extends: 1,
    model: 1,
    model: 2,
    prompt: 1,
    prompt_file: 1,
    summary: 1,
    agents: 1,
    pipeline: 1,
    options: 2,
    drop: 1
  ],
  subdirectories: ["priv/*/migrations"],
  plugins: [Spark.Formatter, Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"]
]
