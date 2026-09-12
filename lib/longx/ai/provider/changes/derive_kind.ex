defmodule Longx.AI.Provider.Changes.DeriveKind do
  @moduledoc """
  `kind` when the caller did not choose one: `api.openai.com` is OpenAI —
  the only host whose reasoning ciphertext we may replay to it — everything
  else is merely OpenAI-compatible. A proxy in front of OpenAI must say
  `kind: :openai_compatible` explicitly, since its key pool cannot decrypt
  what another key produced.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    if given?(changeset, :kind) do
      changeset
    else
      Ash.Changeset.force_change_attribute(
        changeset,
        :kind,
        Longx.AI.Provider.kind_for_base_url(Ash.Changeset.get_attribute(changeset, :base_url))
      )
    end
  end

  # an attribute default is applied before changes run, so the params tell us
  # whether the caller actually made a choice
  defp given?(%{params: params}, key),
    do: Map.has_key?(params, key) or Map.has_key?(params, Atom.to_string(key))
end
