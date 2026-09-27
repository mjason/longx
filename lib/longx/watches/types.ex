defmodule Longx.Watches.Types do
  @moduledoc """
  The typed results of the Longx.Watches actions the page reads, as Ash map
  types with a GraphQL name: only a `NewType` with `graphql_type/1` is an
  object type to AshGraphql (an inline `:map` with `fields` is a `Json`
  scalar); nested `fields` are typed with it, named `<type>_<field>`.
  """

  defmodule DryRun do
    @moduledoc "the result of `Longx.Watches.Watch.dry_run`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          ok: [type: :boolean, allow_nil?: false],
          result: [type: :string, allow_nil?: false],
          log: [type: {:array, :string}, allow_nil?: false],
          sends: [type: {:array, :string}, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :dry_run
  end

  defmodule ListAll do
    @moduledoc "the result of `Longx.Watches.Watch.list_all`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [fields: [watches: [type: {:array, :map}, allow_nil?: false]]]

    def graphql_type(_), do: :list_all
  end
end
