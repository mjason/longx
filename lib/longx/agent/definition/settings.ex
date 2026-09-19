defmodule Longx.Agent.Definition.Settings do
  @moduledoc """
  What the settings page decides about the native kernel — the topmost
  layer of every agent's description, in the same terms as `agent.exs`
  but from the database: how deep a team may nest (`max_depth`), how
  many children an agent may have at once (`max_children`), how long an
  idle agent stays (`idle_minutes`), the model a child runs on when its
  role names none (`child_model` / `child_effort`), and the machine's guards on
  the agent's commands — `command_oom_priority` (the tree's `oom_score_adj`:
  the kernel kills the agent's command before anything else), `command_memory_percent`
  (each command's address space capped at this share of RAM; 0 = no cap) and
  `memory_floor_percent` (free memory below this share → every running
  command is killed, `Longx.System.Pressure`; 0 = off).
  No role ships with the kernel, so no role has a fixed model here: a role's
  model is its own declaration.

  The global values are one `Longx.System.Setting` (`agent_kernel`, JSON);
  a project's `agent_settings` map overrides what it sets. `for_project/1`
  is what the kernel is given (`Longx.Projects` hands it a function read
  per turn, like the trust switch) and what `Longx.Agent.Definition.Loader` applies.
  """

  @key "agent_kernel"
  @fields [
    :max_depth,
    :max_children,
    :idle_minutes,
    :model_retries,
    :command_oom_priority,
    :command_memory_percent,
    :memory_floor_percent,
    :child_model,
    :child_effort
  ]
  @defaults %{
    max_depth: 2,
    max_children: 4,
    idle_minutes: 30,
    # a model call that breaks (a 5xx, a dropped stream, silence) is tried this
    # many more times before the chain's next model, or the person, takes over
    model_retries: 3,
    # a GPU backtest once took the whole machine down: the driver's memory is no
    # process's, so the OOM killer went for Firefox and the box was rebooted
    command_oom_priority: 800,
    command_memory_percent: 50,
    memory_floor_percent: 8,
    child_model: nil,
    child_effort: nil
  }

  @type t :: %{
          max_depth: pos_integer,
          max_children: pos_integer,
          idle_minutes: pos_integer,
          model_retries: non_neg_integer,
          command_oom_priority: non_neg_integer,
          command_memory_percent: non_neg_integer,
          memory_floor_percent: non_neg_integer,
          child_model: String.t() | nil,
          child_effort: String.t() | nil
        }

  @spec fields() :: [atom]
  def fields, do: @fields

  @spec defaults() :: t
  def defaults, do: @defaults

  @doc "The global settings: the defaults under what was saved."
  @spec global() :: t
  def global do
    case Longx.System.get_setting(@key) do
      {:ok, %{value: json}} when is_binary(json) -> Map.merge(@defaults, decode(json))
      _ -> @defaults
    end
  end

  @doc "The saved overrides alone (what the page edits), nil values dropped."
  @spec global_overrides() :: map
  def global_overrides do
    case Longx.System.get_setting(@key) do
      {:ok, %{value: json}} when is_binary(json) -> decode(json)
      _ -> %{}
    end
  end

  @doc """
  Saves the global settings: the given keys replace the saved ones (nil
  clears a key back to the default). Validated: counts ≥ 1, models known,
  levels the model offers. `{:error, %{field, message}}`.
  """
  @spec put_global(map) :: {:ok, t} | {:error, %{field: atom, message: String.t()}}
  def put_global(attrs) when is_map(attrs) do
    # a key given as nil clears the saved value; one absent stays
    cleared = for {key, nil} <- attrs, field = to_field(key), field in @fields, do: field
    merged = global_overrides() |> Map.drop(cleared) |> Map.merge(normalise(attrs))

    with :ok <- validate(merged),
         {:ok, _} <- Longx.System.put_setting(@key, Jason.encode!(merged)) do
      {:ok, global()}
    else
      {:error, %{field: _} = error} -> {:error, error}
      {:error, other} -> {:error, %{field: :max_depth, message: inspect(other)}}
    end
  end

  @doc "The settings a project runs under: its overrides on the global ones."
  @spec for_project(map) :: t
  def for_project(%{agent_settings: overrides}),
    do: Map.merge(global(), normalise(overrides || %{}))

  @spec for_project_id(String.t() | nil) :: t
  def for_project_id(nil), do: global()

  def for_project_id(project_id) do
    case Ash.get(Longx.Projects.Project, project_id) do
      {:ok, project} -> for_project(project)
      _ -> global()
    end
  end

  @doc "Validates a project's overrides (the same rules; nil = inherit)."
  @spec validate(map) :: :ok | {:error, %{field: atom, message: String.t()}}
  def validate(attrs) when is_map(attrs) do
    attrs = normalise(attrs)

    Enum.find_value(@fields, :ok, fn field ->
      case check(field, Map.get(attrs, field), attrs) do
        :ok -> nil
        {:error, message} -> {:error, %{field: field, message: message}}
      end
    end)
  end

  @spec idle_ms(t) :: pos_integer
  def idle_ms(%{idle_minutes: minutes}), do: minutes * 60_000

  # keys as atoms, nils out, strings trimmed
  defp normalise(attrs) do
    for {key, value} <- attrs,
        field = to_field(key),
        field in @fields,
        value = clean(value),
        not is_nil(value),
        into: %{},
        do: {field, value}
  end

  defp to_field(key) when is_atom(key), do: key

  defp to_field(key) when is_binary(key) do
    Enum.find(@fields, &(Atom.to_string(&1) == key))
  end

  defp clean(value) when is_binary(value),
    do: value |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))

  defp clean(value), do: value

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> normalise(map)
      _ -> %{}
    end
  end

  defp check(_field, nil, _attrs), do: :ok

  defp check(field, value, _attrs) when field in [:max_depth, :max_children, :idle_minutes] do
    if is_integer(value) and value >= 1,
      do: :ok,
      else: {:error, "must be a whole number of at least 1"}
  end

  defp check(:model_retries, value, _attrs) do
    if is_integer(value) and value >= 0 and value <= 20,
      do: :ok,
      else: {:error, "must be a whole number from 0 to 20"}
  end

  defp check(:command_oom_priority, value, _attrs) do
    if is_integer(value) and value >= 0 and value <= 1000,
      do: :ok,
      else: {:error, "must be a whole number from 0 to 1000"}
  end

  defp check(:command_memory_percent, value, _attrs) do
    if is_integer(value) and value >= 0 and value <= 100,
      do: :ok,
      else: {:error, "must be a whole number from 0 to 100"}
  end

  defp check(:memory_floor_percent, value, _attrs) do
    if is_integer(value) and value >= 0 and value <= 50,
      do: :ok,
      else: {:error, "must be a whole number from 0 to 50"}
  end

  defp check(:child_model, slug, attrs) do
    effort = Map.get(attrs, :child_effort)

    with {:ok, _} <- Longx.AI.thread_options(slug),
         :ok <- Longx.AI.check_effort(slug, effort) do
      :ok
    else
      {:error, {:unknown_model, _}} -> {:error, "unknown model #{slug}"}
      {:error, {:unknown_effort, e}} -> {:error, "the model offers no level #{e}"}
      {:error, other} -> {:error, inspect(other)}
    end
  end

  defp check(:child_effort, _effort, attrs) do
    # a level without a model means nothing; with one it was checked above
    if Map.get(attrs, :child_model),
      do: :ok,
      else: {:error, "a level needs a model"}
  end
end
