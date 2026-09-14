defmodule Longx.AI.Provider.Validations.NoDefaultModel do
  @moduledoc "A provider cannot be deleted while one of its models is the global default."
  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def validate(changeset, _opts, _context) do
    default? =
      Longx.AI.Model
      |> Ash.Query.filter(provider_id == ^changeset.data.id and default == true)
      |> Ash.exists?()

    if default?,
      do: {:error, field: :id, message: "它的模型是默认模型，先把另一个模型设为默认"},
      else: :ok
  end
end
