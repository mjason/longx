defmodule Longx.Credentials.Types do
  @moduledoc """
  The typed results of the Longx.Credentials actions the page reads, as Ash map
  types with a GraphQL name: only a `NewType` with `graphql_type/1` is an
  object type to AshGraphql (an inline `:map` with `fields` is a `Json`
  scalar); nested `fields` are typed with it, named `<type>_<field>`.
  """

  defmodule LoginUrl do
    @moduledoc "the result of `Longx.Credentials.Credential.login_url`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          url: [type: :string, allow_nil?: false],
          redirect_uri: [type: :string, allow_nil?: false],
          # a loopback redirect: a browser on another machine lands on an
          # unreachable page and the person pastes its address (complete_url)
          loopback: [type: :boolean, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :login_url
  end

  defmodule DeviceBegin do
    @moduledoc "the result of `Longx.Credentials.Credential.device_begin`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          state: [type: :string, allow_nil?: false],
          user_code: [type: :string, allow_nil?: false],
          verification_url: [type: :string, allow_nil?: false],
          interval: [type: :integer, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :device_begin
  end

  defmodule DevicePoll do
    @moduledoc "the result of `Longx.Credentials.Credential.device_poll`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          status: [type: :string, allow_nil?: false],
          message: [type: :string]
        ]
      ]

    def graphql_type(_), do: :device_poll
  end

  defmodule RedirectUri do
    @moduledoc "the result of `Longx.Credentials.Credential.redirect_uri`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [fields: [uri: [type: :string, allow_nil?: false]]]

    def graphql_type(_), do: :redirect_uri
  end
end
