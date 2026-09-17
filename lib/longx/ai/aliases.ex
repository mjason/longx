defmodule Longx.AI.Aliases do
  @moduledoc """
  Names for models that survive a migration: three **tiers** every
  installation has — `flagship` (旗舰), `advanced` (高级), `standard`
  (普通) — and any **aliases** a team agrees on (青龙, 朱雀 …). Each maps
  to an ordered chain of model slugs: the first is the one to use, the
  rest are fallbacks when it fails (quota gone, auth refused, upstream
  down). A description (`model "flagship"`), a child's default model, the
  reviewer model, the composer — all may name a tier or alias, or still a
  concrete slug; `Longx.AI` resolves them (`resolve_targets/1`). A tier
  left unmapped means the default model. One `Longx.System.Setting`
  (`model_aliases`, JSON); the settings page edits it.
  """

  alias Longx.AI

  @key "model_aliases"
  @tiers ["flagship", "advanced", "standard"]
  @labels %{"flagship" => "旗舰", "advanced" => "高级", "standard" => "普通"}

  @type entry :: %{name: String.t(), label: String.t(), models: [String.t()], builtin?: boolean}

  @spec tiers() :: [String.t()]
  def tiers, do: @tiers

  @doc "The label of a tier (its Chinese name), the name itself for an alias."
  @spec label(String.t()) :: String.t()
  def label(name), do: Map.get(@labels, name, name)

  @doc "Every tier (always, mapped or not) and every alias, tiers first."
  @spec all() :: [entry]
  def all do
    saved = saved()

    tiers =
      for tier <- @tiers,
          do: %{name: tier, label: label(tier), models: Map.get(saved, tier, []), builtin?: true}

    aliases =
      for {name, models} <- saved,
          name not in @tiers,
          do: %{name: name, label: name, models: models, builtin?: false}

    tiers ++ Enum.sort_by(aliases, & &1.name)
  end

  @doc """
  The chain of slugs behind a name: the saved one, or — for an unmapped
  tier — the default model's slug. `:error` for anything that is no tier
  or alias (a slug, an unknown name).
  """
  @spec resolve(String.t() | nil) :: {:ok, [String.t()]} | :error
  def resolve(name) when is_binary(name) do
    case {Map.get(saved(), name), name in @tiers} do
      {[_ | _] = models, _} -> {:ok, models}
      {_, true} -> with {:ok, slug} <- default_slug(), do: {:ok, [slug]}
      _ -> :error
    end
  end

  def resolve(_name), do: :error

  @doc "Whether the name is a tier or a saved alias."
  @spec alias?(String.t() | nil) :: boolean
  def alias?(name), do: match?({:ok, _}, resolve(name))

  @doc """
  Maps a tier or alias to a chain of model slugs (`[]` unmaps a tier). The
  name must be a word (letters, digits, `_`, `-`), must not be a model's
  slug; every slug must exist. `{:error, %{field, message}}`.
  """
  @spec put(String.t(), [String.t()]) ::
          {:ok, entry} | {:error, %{field: atom, message: String.t()}}
  def put(name, models) when is_binary(name) and is_list(models) do
    name = String.trim(name)
    models = models |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

    with :ok <- check_name(name),
         :ok <- check_models(name, models),
         :ok <- save(Map.put(saved(), name, models)) do
      {:ok, Enum.find(all(), &(&1.name == name))}
    end
  end

  @doc "Removes an alias; a tier cannot go (map it to `[]` instead)."
  @spec delete(String.t()) :: :ok | {:error, %{field: atom, message: String.t()}}
  def delete(name) when name in @tiers,
    do:
      {:error,
       %{field: :name, message: "#{name} is a tier; map it to no model instead of removing it"}}

  def delete(name) when is_binary(name), do: save(Map.delete(saved(), name))

  defp check_name(""), do: {:error, %{field: :name, message: "a name is needed"}}

  defp check_name(name) do
    cond do
      not Regex.match?(~r/^[\p{L}\p{N}_-]+$/u, name) ->
        {:error, %{field: :name, message: "a name is letters, digits, _ or - (no spaces)"}}

      match?({:ok, %AI.Model{}}, AI.get_model_by_slug(name)) ->
        {:error,
         %{field: :name, message: "#{name} is a model's slug; an alias needs a name of its own"}}

      true ->
        :ok
    end
  end

  defp check_models(name, models) do
    known = AI.list_models!() |> Enum.map(& &1.slug)

    cond do
      models == [] and name not in @tiers ->
        {:error, %{field: :models, message: "an alias needs at least one model"}}

      (unknown = Enum.reject(models, &(&1 in known))) != [] ->
        {:error, %{field: :models, message: "unknown models: #{Enum.join(unknown, ", ")}"}}

      true ->
        :ok
    end
  end

  defp saved do
    case Longx.System.get_setting(@key) do
      {:ok, %{value: json}} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) ->
            for {k, v} <- map,
                is_binary(k),
                is_list(v),
                into: %{},
                do: {k, Enum.filter(v, &is_binary/1)}

          _ ->
            %{}
        end

      _ ->
        %{}
    end
  end

  defp save(map) do
    case Longx.System.put_setting(@key, Jason.encode!(map)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, %{field: :name, message: inspect(reason)}}
    end
  end

  defp default_slug do
    case AI.default_model() do
      {:ok, %AI.Model{slug: slug}} when is_binary(slug) -> {:ok, slug}
      _ -> :error
    end
  end
end
