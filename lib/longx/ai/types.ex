defmodule Longx.AI.Types do
  @moduledoc """
  The typed results of the Longx.AI actions the page reads, as Ash map
  types with a GraphQL name: only a `NewType` with `graphql_type/1` is an
  object type to AshGraphql (an inline `:map` with `fields` is a `Json`
  scalar); nested `fields` are typed with it, named `<type>_<field>`.
  """

  defmodule DiscoverModels do
    @moduledoc "the result of `Longx.AI.Provider.discover_models`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          ok: [type: :boolean, allow_nil?: false],
          error: [type: :string],
          models: [type: {:array, :map}, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :discover_models
  end

  defmodule CheckModel do
    @moduledoc "the result of `Longx.AI.Model.check_model`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          ok: [type: :boolean, allow_nil?: false],
          latency_ms: [type: :integer],
          error: [type: :string]
        ]
      ]

    def graphql_type(_), do: :check_model
  end

  defmodule ModelDefault do
    @moduledoc "`Longx.AI.Model.default_model_setting` and other actions returning `@default_fields`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          name: [type: :string, allow_nil?: false],
          slug: [type: :string],
          kind: [type: :atom, allow_nil?: false, constraints: [one_of: [:tier, :alias, :model]]]
        ]
      ]

    def graphql_type(_), do: :model_default
  end

  defmodule ModelAlias do
    @moduledoc "`Longx.AI.Model.model_aliases` and other actions returning `@alias_fields`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          name: [type: :string, allow_nil?: false],
          label: [type: :string, allow_nil?: false],
          models: [type: {:array, :string}, allow_nil?: false],
          builtin: [type: :boolean, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :model_alias
  end

  defmodule ListPresets do
    @moduledoc "the result of `Longx.AI.Preset.list_presets`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          slug: [type: :string, allow_nil?: false],
          name: [type: :string, allow_nil?: false],
          kind: [type: :atom, allow_nil?: false],
          base_url: [type: :string, allow_nil?: false],
          supports_hosted_web_search: [type: :boolean, allow_nil?: false],
          key_env: [type: :string, allow_nil?: false],
          key_url: [type: :string, allow_nil?: false],
          docs_url: [type: :string, allow_nil?: false],
          installed: [type: :boolean, allow_nil?: false],
          # the key is a login (a subscription), not a string
          credential: [type: :boolean, allow_nil?: false],
          provider_id: [type: :uuid],
          models: [type: {:array, :map}, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :list_presets
  end

  defmodule ApplyPreset do
    @moduledoc "the result of `Longx.AI.Preset.apply_preset`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          provider_id: [type: :uuid, allow_nil?: false],
          model_ids: [type: {:array, :uuid}, allow_nil?: false],
          # the OAuth2 credential a subscription preset made (the login comes next)
          credential_id: [type: :uuid]
        ]
      ]

    def graphql_type(_), do: :apply_preset
  end
end
