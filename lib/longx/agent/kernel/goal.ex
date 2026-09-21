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

  # every model call while a goal is set counts against it — and the page hears
  # of it at once (the bar once read 0 · 0 秒 for a whole goal, the counters only
  # ever sent with a status change)
  def charge_goal(%State{goal: nil} = state, _tokens), do: state

  def charge_goal(%State{goal: goal} = state, tokens) do
    goal = goal |> Map.update("tokensUsed", tokens, &(&1 + tokens)) |> with_time()
    emit(state, "thread/goal/updated", %{"goal" => Map.delete(goal, "startedAt")})
    %{state | goal: goal}
  end

  # a goal read back from the view (a new process): the clock resumes where the
  # view's seconds left it — the view never carries `startedAt`
  def restore(nil), do: nil
  def restore(%{"startedAt" => _} = goal), do: goal

  def restore(goal),
    do: Map.put(goal, "startedAt", System.system_time(:second) - (goal["timeUsedSeconds"] || 0))

  ## The continuation

  # codex's continuation steering item (templates/goals/continuation.md, the
  # update_plan paragraph left out as codex does without that tool); the
  # objective is user data inside <objective>, so its angle brackets are escaped
  @continuation File.read!(Path.join(:code.priv_dir(:longx), "agent/goal/continuation.md"))

  def continuation(goal, _round) do
    used = goal["tokensUsed"] || 0
    budget = goal["tokenBudget"]

    {budget_text, remaining} =
      if is_integer(budget),
        do: {Integer.to_string(budget), Integer.to_string(max(budget - used, 0))},
        else: {"none", "unbounded"}

    @continuation
    |> String.replace("{{ objective }}", escape_xml(goal["objective"] || ""))
    |> String.replace("{{ tokens_used }}", Integer.to_string(used))
    |> String.replace("{{ token_budget }}", budget_text)
    |> String.replace("{{ remaining_tokens }}", remaining)
  end

  defp escape_xml(text),
    do:
      text
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
end
