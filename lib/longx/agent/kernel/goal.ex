defmodule Longx.Agent.Kernel.Goal do
  @moduledoc false
  # The thread's goal (codex's shape): updates, the token charge, the elapsed time.

  alias Longx.Agent.Kernel.State
  import Longx.Agent.Kernel.State

  ## The goal

  @goal_defaults %{
    "status" => "active",
    "tokenBudget" => nil,
    "tokensUsed" => 0,
    "timeUsedSeconds" => 0
  }

  def update_goal(%State{goal: goal} = state, attrs) do
    base = goal || Map.put(@goal_defaults, "startedAt", System.system_time(:second))

    # a status change drops the old reason unless the new one brings its own
    # (`rounds` / `budget` from the plug, the model's sentence from `update_goal`)
    goal =
      base
      |> then(&if(Map.has_key?(attrs, "status"), do: Map.delete(&1, "reason"), else: &1))
      |> Map.merge(Map.take(attrs, ["objective", "status", "tokenBudget", "reason"]))
      |> Map.put_new("objective", "")
      |> with_time()

    emit(state, "thread/goal/updated", %{"goal" => Map.delete(goal, "startedAt")})
    %{state | goal: goal}
  end

  def with_time(%{"startedAt" => at} = goal) when is_integer(at),
    do: Map.put(goal, "timeUsedSeconds", System.system_time(:second) - at)

  def with_time(goal), do: goal

  # every model call while a goal is set counts against it
  def charge_goal(%State{goal: nil} = state, _tokens), do: state

  def charge_goal(%State{goal: goal} = state, tokens),
    do: %{state | goal: Map.update(goal, "tokensUsed", tokens, &(&1 + tokens))}
end
