defmodule Longx.AI.Model.Import do
  @moduledoc false
  require Ash.Query
  alias Longx.AI

  def run(%{provider_id: provider_id, upstream_id: upstream_id} = attributes) do
    :global.trans(
      {{__MODULE__, provider_id, upstream_id}, self()},
      fn ->
        query =
          AI.Model
          |> Ash.Query.filter(provider_id == ^provider_id and upstream_id == ^upstream_id)
          |> Ash.Query.sort(inserted_at: :asc, id: :asc)
          |> Ash.Query.limit(1)

        case Ash.read(query) do
          {:ok, [existing]} -> {:ok, existing}
          {:ok, []} -> AI.create_model(Map.reject(attributes, fn {_, value} -> is_nil(value) end))
          {:error, _} = error -> error
        end
      end,
      [node()]
    )
  end
end
