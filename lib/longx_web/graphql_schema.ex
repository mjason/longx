defmodule LongxWeb.GraphqlSchema do
  @moduledoc """
  The GraphQL API: every domain's `graphql do … end` block, one schema.
  `priv/schema.graphql` is written on every recompilation
  (`auto_generate_sdl_file?`) and committed — it is the contract the
  TypeScript client (graphql-codegen) and any other client are generated
  from; precommit fails when the committed file is stale. Streaming stays
  on the Phoenix channels (`LongxWeb.ThreadChannel` and the others): a
  request here is a call, never a stream.
  """

  use Absinthe.Schema

  use AshGraphql,
    domains: [
      Longx.Projects,
      Longx.AI,
      Longx.System,
      Longx.Chrome,
      Longx.Credentials,
      Longx.Watches
    ],
    generate_sdl_file: "priv/schema.graphql",
    auto_generate_sdl_file?: true

  query do
  end

  mutation do
  end
end
