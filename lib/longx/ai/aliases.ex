defmodule Longx.AI.Aliases do
  @moduledoc """
  Names for models that survive a migration: three **tiers** every
  installation has — `ultra` (旗舰), `pro` (高级), `plus`
  (普通) — and any **aliases** a team agrees on (青龙, 朱雀 …). Each maps
  to an ordered chain of model slugs: the first is the one to use, the
  rest are fallbacks when it fails (quota gone, auth refused, upstream
  down). A description (`model "ultra"`), a child's default model, the
  the composer — all may name a tier or alias, or still a
  concrete slug; `Longx.AI` resolves them (`resolve_targets/1`). A tier
  left unmapped means the default model. **Each model of a chain carries its
  own reasoning level** (nil: the model's default): `plus` and `pro` may be
  the same model at `low` and `xhigh`, and a fallback of another provider
  runs at a level it declares — the levels' words differ by provider. One
  `Longx.System.Setting` (`model_aliases`, JSON `{name: [{slug, effort}]}`;
  a chain saved as plain slugs reads as every model at its default); the
  settings page edits it.
  """

  alias Longx.AI

  @key "model_aliases"
  @tiers ["ultra", "pro", "plus"]
  @labels %{"ultra" => "旗舰", "pro" => "高级", "plus" => "普通"}

  @type link :: %{slug: String.t(), effort: String.t() | nil}
  @type entry :: %{
          name: String.t(),
          label: String.t(),
          models: [String.t()],
          efforts: [String.t() | nil],
          builtin?: boolean
        }

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
      for tier <- @tiers, do: entry(tier, Map.get(saved, tier, []), true)

    aliases =
      for {name, links} <- saved, name not in @tiers, do: entry(name, links, false)

    tiers ++ Enum.sort_by(aliases, & &1.name)
  end

  defp entry(name, links, builtin?) do
    %{
      name: name,
      label: label(name),
      models: Enum.map(links, & &1.slug),
      efforts: Enum.map(links, & &1.effort),
      builtin?: builtin?
    }
  end

  @doc """
  The chain of slugs behind a name: the saved one, or — for an unmapped
  tier — the default model's slug. `:error` for anything that is no tier
  or alias (a slug, an unknown name).
  """
  @spec resolve(String.t() | nil) :: {:ok, [String.t()]} | :error
  def resolve(name) do
    with {:ok, links} <- resolve_entries(name), do: {:ok, Enum.map(links, & &1.slug)}
  end

  @doc "The chain behind a name with each model's level (nil: the model's default)."
  @spec resolve_entries(String.t() | nil) :: {:ok, [link]} | :error
  def resolve_entries(name) when is_binary(name) do
    name = tier_name(name)

    case {Map.get(saved(), name), name in @tiers} do
      {[_ | _] = links, _} -> {:ok, links}
      {_, true} -> with {:ok, slug} <- default_slug(), do: {:ok, [%{slug: slug, effort: nil}]}
      _ -> :error
    end
  end

  def resolve_entries(_name), do: :error

  @doc "Whether the name is a tier or a saved alias."
  @spec alias?(String.t() | nil) :: boolean
  def alias?(name), do: match?({:ok, _}, resolve(name))

  @doc """
  Maps a tier or alias to a chain of model slugs (`[]` unmaps a tier), each
  at the level in `efforts` beside it (nil or "" — or none given — for the
  model's default). The name must be a word (letters, digits, `_`, `-`),
  must not be a model's slug; every slug must exist, every level be one its
  model declares. `{:error, %{field, message}}`.
  """
  @spec put(String.t(), [String.t()], [String.t() | nil]) ::
          {:ok, entry} | {:error, %{field: atom, message: String.t()}}
  def put(name, models, efforts \\ [])
      when is_binary(name) and is_list(models) and is_list(efforts) do
    name = name |> String.trim() |> tier_name()

    links =
      models
      |> Enum.with_index()
      |> Enum.map(fn {slug, i} ->
        %{slug: String.trim(slug), effort: blank_nil(Enum.at(efforts, i))}
      end)
      |> Enum.reject(&(&1.slug == ""))
      |> Enum.uniq_by(& &1.slug)

    with :ok <- check_name(name),
         :ok <- check_models(name, Enum.map(links, & &1.slug)),
         :ok <- check_efforts(links),
         :ok <- save(Map.put(saved(), name, links)) do
      {:ok, Enum.find(all(), &(&1.name == name))}
    end
  end

  defp blank_nil(nil), do: nil

  defp blank_nil(effort) when is_binary(effort) do
    case String.trim(effort) do
      "" -> nil
      e -> e
    end
  end

  @doc "Removes an alias; a tier cannot go (map it to `[]` instead)."
  @spec delete(String.t()) :: :ok | {:error, %{field: atom, message: String.t()}}
  def delete(name) when name in @tiers,
    do:
      {:error,
       %{field: :name, message: "#{name} is a tier; map it to no model instead of removing it"}}

  def delete(name) when is_binary(name), do: save(Map.delete(saved(), name))

  # Ultra, PRO, plus: a tier is known whatever the case
  defp tier_name(name) do
    down = String.downcase(name)
    if down in @tiers, do: down, else: name
  end

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

  defp check_efforts(links) do
    levels = Map.new(AI.list_models!(), &{&1.slug, &1.reasoning_levels || []})

    undeclared? = fn %{slug: slug, effort: effort} ->
      is_binary(effort) and levels[slug] != [] and effort not in levels[slug]
    end

    case Enum.find(links, undeclared?) do
      nil ->
        :ok

      %{slug: slug, effort: effort} ->
        {:error,
         %{
           field: :efforts,
           message: "#{slug} has no level #{effort}; it declares #{Enum.join(levels[slug], ", ")}"
         }}
    end
  end

  # {name => [%{slug, effort}]}; a chain saved as plain slugs (before levels) is every model at its default
  defp saved do
    case Longx.System.get_setting(@key) do
      {:ok, %{value: json}} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) ->
            for {k, v} <- map,
                is_binary(k),
                is_list(v),
                into: %{},
                do: {k, Enum.flat_map(v, &link/1)}

          _ ->
            %{}
        end

      _ ->
        %{}
    end
  end

  defp link(slug) when is_binary(slug), do: [%{slug: slug, effort: nil}]

  defp link(%{"slug" => slug} = l) when is_binary(slug),
    do: [%{slug: slug, effort: if(is_binary(l["effort"]), do: l["effort"])}]

  defp link(_), do: []

  defp save(map) do
    json =
      Map.new(map, fn {name, links} ->
        {name, Enum.map(links, &%{"slug" => &1.slug, "effort" => &1.effort})}
      end)

    case Longx.System.put_setting(@key, Jason.encode!(json)) do
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
