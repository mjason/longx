defmodule Longx.AI.Preset do
  @moduledoc """
  A resource without data: the settings page's door to `Longx.AI.Presets` —
  the catalogue of ready-made providers, and applying one.
  """

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.AI,
    extensions: [AshTypescript.Resource]

  alias Longx.AI.Presets

  typescript do
    type_name "Preset"
  end

  actions do
    # the cards: each preset with its models (an array of typed maps is not
    # selectable in ash_typescript 0.18's field types; the model shape —
    # upstreamId, slug, name, contextWindow, reasoningLevels, reasoningEffort,
    # image, recommended, installed — is typed client-side). `installed` says
    # whether the provider (and a model) already exists, so the page can offer
    # "add the missing ones" instead of a fresh setup.
    action :list_presets, {:array, :map} do
      constraints items: [
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

      run fn _input, _ ->
        # an untyped map crosses the wire as is: camelCase it here
        {:ok,
         Enum.map(Presets.describe(), fn preset ->
           Map.update!(preset, :models, fn models -> Enum.map(models, &camelize/1) end)
         end)}
      end
    end

    # one step: the key, the models to add, which becomes the default
    action :apply_preset, :map do
      constraints fields: [
                    provider_id: [type: :uuid, allow_nil?: false],
                    model_ids: [type: {:array, :uuid}, allow_nil?: false],
                    # the OAuth2 credential a subscription preset made (the login comes next)
                    credential_id: [type: :uuid]
                  ]

      argument :slug, :string, allow_nil?: false
      argument :api_key, :string
      # upstream ids; absent = the preset's recommended models
      argument :models, {:array, :string}
      # the upstream id to make the global default
      argument :make_default, :string

      run fn input, _ ->
        args = input.arguments

        opts =
          [api_key: args[:api_key]]
          |> put_if(:models, args[:models])
          |> put_if(:make_default, args[:make_default])

        case Presets.apply(args.slug, opts) do
          {:ok, %{provider: provider, models: models, credential: credential}} ->
            {:ok,
             %{
               provider_id: provider.id,
               model_ids: Enum.map(models, & &1.id),
               credential_id: credential && credential.id
             }}

          {:error, :unknown_preset} ->
            argument_error(:slug, "没有这个模版")

          {:error, {:unknown_model, id}} ->
            argument_error(:models, "模版里没有 #{id}")

          {:error, other} ->
            {:error, other}
        end
      end
    end
  end

  defp camelize(map) do
    Map.new(map, fn {key, value} ->
      <<first, rest::binary>> = key |> Atom.to_string() |> Macro.camelize()
      {String.downcase(<<first>>) <> rest, value}
    end)
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  defp argument_error(field, message) do
    {:error,
     Ash.Error.to_error_class(
       Ash.Error.Changes.InvalidArgument.exception(field: field, message: message)
     )}
  end
end
