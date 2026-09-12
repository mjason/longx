defmodule Longx.Repo.Migrations.BackfillOpenaiProviderKind do
  @moduledoc """
  `kind` arrived after providers existed: rows pointing at OpenAI's own API
  were created before the column and sit on the `openai_compatible` default,
  which would deny them their own encrypted reasoning (see Longx.AI.Gateway).
  Same rule as Longx.AI.Provider.kind_for_base_url/1.
  """

  use Ecto.Migration

  def up do
    execute """
    UPDATE ai_providers SET kind = 'openai'
    WHERE base_url LIKE 'https://api.openai.com/%' OR base_url = 'https://api.openai.com'
    """
  end

  def down, do: :ok
end
