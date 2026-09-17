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
    instructions: 1
  ],
  subdirectories: ["priv/*/migrations"],
  plugins: [Spark.Formatter, Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"]
]
