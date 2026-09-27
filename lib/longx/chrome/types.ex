defmodule Longx.Chrome.Types do
  @moduledoc """
  The typed results of `Longx.Chrome.Bridge`'s actions, as Ash map types
  with a GraphQL name: an inline `:map` with `fields` on a generic action
  is a `Json` scalar to AshGraphql — only a `NewType` with `graphql_type/1`
  becomes an object type, its nested `fields` typed with it (named
  `<type>_<field>`) and a nested NewType by its own name.
  """

  defmodule Ok do
    @moduledoc false
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [fields: [ok: [type: :boolean, allow_nil?: false]]]

    def graphql_type(_), do: :ok
  end

  defmodule BrowserTabs do
    @moduledoc "A session's tabs in one browser."
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          thread_id: [type: :string, allow_nil?: false],
          title: [type: :string, allow_nil?: false],
          tabs: [type: :integer, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :chrome_browser_tabs
  end

  defmodule BrowserRow do
    @moduledoc "One paired browser with its live state (`Longx.Chrome.directory/0`)."
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          id: [type: :string, allow_nil?: false],
          name: [type: :string, allow_nil?: false],
          device: [type: :map, allow_nil?: false],
          status: [type: :string, allow_nil?: false],
          connected: [type: :boolean, allow_nil?: false],
          max_tabs: [type: :integer, allow_nil?: false],
          origins: [type: :map, allow_nil?: false],
          last_seen_at: [type: :utc_datetime],
          approved_at: [type: :utc_datetime],
          tabs: [type: {:array, BrowserTabs}, allow_nil?: false, constraints: [nil_items?: false]],
          aliases: [type: {:array, :string}, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :chrome_browser
  end

  defmodule Browsers do
    @moduledoc false
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          browsers: [
            type: {:array, BrowserRow},
            allow_nil?: false,
            constraints: [nil_items?: false]
          ]
        ]
      ]

    def graphql_type(_), do: :chrome_browsers
  end

  defmodule Alias do
    @moduledoc false
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          name: [type: :string, allow_nil?: false],
          browsers: [type: {:array, :string}, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :chrome_alias
  end

  defmodule Aliases do
    @moduledoc false
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          aliases: [type: {:array, Alias}, allow_nil?: false, constraints: [nil_items?: false]],
          default: [type: :string]
        ]
      ]

    def graphql_type(_), do: :chrome_aliases
  end

  defmodule Extension do
    @moduledoc false
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          url: [type: :string, allow_nil?: false],
          version: [type: :string],
          built: [type: :boolean, allow_nil?: false],
          minimum_chrome: [type: :string, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :chrome_extension
  end
end
