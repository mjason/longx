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

    goal =
      base
      |> Map.merge(Map.take(attrs, ["objective", "status", "tokenBudget"]))
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
