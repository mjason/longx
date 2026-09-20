defmodule Longx.Agent.Plugs.Goal do
  @moduledoc """
  Goal mode, codex's shape as a strategy plug: the model has `create_goal`
  / `update_goal` / `get_goal` (it only creates one when asked); while
  the thread's goal is `active`, the `:turn_end` phase continues the turn
  with a continuation step that names the objective, until the model marks
  it `complete` (or `blocked`), the token budget is spent, or `max_rounds:`
  (8) continuations happened in one turn — then the goal is marked
  `blocked` rather than looping. The person's `/goal` sets the same goal
  through `Longx.Agent.set_goal/2`; the goal lives in the thread's view
  (`thread/goal/updated`).
  """

  use Longx.Agent.Plug

  @defaults [max_rounds: 8]

  # codex's goal extension (codex-rs/ext/goal): the rules live on the tools,
  # nothing in the system prompt — its words verbatim, since ours once let a
  # coordinator infer a goal from "have the researcher and coder look into it"
  tool :create_goal,
       """
       Create a goal only when explicitly requested by the user or system/developer instructions; do not infer goals from ordinary tasks.
       Set token_budget only when an explicit token budget is requested. Fails if an unfinished goal exists; use update_goal only for status.
       """ do
    param :objective,
          :string,
          "Required. The concrete objective to start pursuing. This starts a new active goal when no goal exists or replaces the current goal when it is complete.",
          required: true

    param :token_budget,
          :integer,
          "Positive token budget for the new goal. Omit unless explicitly requested."
  end

  tool :update_goal,
       """
       Update the existing goal.
       Set status to `paused` only at the user's explicit request to pause this goal, never on your own initiative. Ask if unclear; a later resume revokes that request. Report the returned status and stop goal work. Budget limits take precedence over pausing.
       Set status to `complete` only when the objective has actually been achieved and no required work remains.
       Set status to `blocked` only when the same blocking condition has repeated for at least three consecutive goal turns, counting the original/user-triggered turn and any automatic continuations, and the agent cannot make meaningful progress without user input or an external-state change.
       If the user resumes a goal that was previously marked `blocked`, treat the resumed run as a fresh blocked audit. If the same blocking condition then repeats for at least three consecutive resumed goal turns, set status to `blocked` again.
       Once the blocked threshold is satisfied, do not keep reporting that you are still blocked while leaving the goal active; set status to `blocked`.
       Do not use `blocked` merely because the work is hard, slow, uncertain, incomplete, or would benefit from clarification.
       Do not mark a goal complete merely because its budget is nearly exhausted or because you are stopping work.
       You cannot use this tool to resume, budget-limit, or usage-limit a goal; those status changes are controlled by the user or system.
       When marking a budgeted goal achieved with status `complete`, report the final token usage from the tool result to the user.
       """ do
    param :status,
          {:enum, ["complete", "blocked", "paused"]},
          "Required. `paused` requires an explicit user request. Set to `complete` only when the objective is achieved and no required work remains. Set to `blocked` only after the same blocking condition has recurred for at least three consecutive goal turns and the agent is at an impasse. After a previously blocked goal is resumed, the resumed run starts a fresh blocked audit.",
          required: true

    # ours: the blocker in a sentence, shown beside 卡住了 on the page
    param :reason,
          :string,
          "When blocked: what stands in the way, in one sentence (shown to the user)"
  end

  tool :get_goal,
       "Get the current goal for this thread, including status, budgets, token and elapsed-time usage, and remaining token budget." do
  end

  @impl true
  def init(opts), do: Keyword.merge(@defaults, opts)

  @impl true
  def call(%Step{phase: :request} = step, _opts), do: Longx.Agent.Plug.mount(step, __MODULE__)

  def call(%Step{phase: :turn_end, assigns: %{goal: %{"status" => "active"} = goal}} = step, opts) do
    rounds = Map.get(step.state, :goal_rounds, 0)
    budget = goal["tokenBudget"]
    used = goal["tokensUsed"] || 0

    cond do
      # a child at work: its report starts the next turn by itself — continuing now
      # only made the model say "waiting" round after round until the cap blocked the goal
      Enum.any?(step.assigns[:children] || [], &(&1.status == "working")) ->
        step

      is_integer(budget) and used >= budget ->
        Step.goal(step, %{"status" => "blocked", "reason" => "budget"})

      rounds >= opts[:max_rounds] ->
        Step.goal(step, %{"status" => "blocked", "reason" => "rounds"})

      true ->
        step
        |> Step.put_state(:goal_rounds, rounds + 1)
        |> Step.continue(continuation(goal, rounds + 1),
          origin: %{"kind" => "goal", "round" => rounds + 1, "objective" => goal["objective"]}
        )
    end
  end

  def call(step, _opts), do: step

  # codex's continuation steering item (templates/goals/continuation.md, the
  # update_plan paragraph left out as codex does without that tool); the
  # objective is user data inside <objective>, so its angle brackets are escaped
  @continuation File.read!(Path.join(:code.priv_dir(:longx), "agent/goal/continuation.md"))
  @external_resource Path.join(:code.priv_dir(:longx), "agent/goal/continuation.md")

  defp continuation(goal, _round) do
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

  ## The tools — codex's answers: the goal as JSON with `remainingTokens`,
  ## and on completion the report the model owes the person

  def create_goal(%{"objective" => objective} = args, ctx) do
    case Longx.Agent.get_goal(ctx.thread_id) do
      {:ok, %{"status" => status}} when status not in ["complete"] ->
        {:error,
         "cannot create a new goal because this thread has an unfinished goal; complete the existing goal first"}

      _ ->
        attrs = %{
          "objective" => String.trim(objective),
          "status" => "active",
          "tokenBudget" => args["token_budget"]
        }

        with {:ok, goal} <- Longx.Agent.set_goal(ctx.thread_id, attrs),
             do: {:ok, response(goal, report: false)}
    end
  end

  def update_goal(args, ctx) do
    attrs =
      args
      |> Map.take(["status", "reason"])
      |> Enum.reject(&is_nil(elem(&1, 1)))
      |> Map.new()

    case Longx.Agent.get_goal(ctx.thread_id) do
      {:ok, nil} ->
        {:error, "cannot update goal because this thread has no goal"}

      _ ->
        with {:ok, goal} <- Longx.Agent.set_goal(ctx.thread_id, attrs),
             do: {:ok, response(goal, report: true)}
    end
  end

  def get_goal(_args, ctx) do
    case Longx.Agent.get_goal(ctx.thread_id) do
      {:ok, nil} -> {:ok, response(nil, report: false)}
      {:ok, goal} -> {:ok, response(goal, report: false)}
    end
  end

  defp response(goal, report: report?) do
    remaining =
      case goal do
        %{"tokenBudget" => budget} when is_integer(budget) ->
          max(budget - (goal["tokensUsed"] || 0), 0)

        _ ->
          nil
      end

    Jason.encode!(%{
      "goal" => goal,
      "remainingTokens" => remaining,
      "completionBudgetReport" => if(report?, do: completion_budget_report(goal), else: nil)
    })
  end

  # codex: nothing to report for a goal without a budget that took no time
  defp completion_budget_report(%{"status" => "complete"} = goal) do
    if is_integer(goal["tokenBudget"]) or (goal["timeUsedSeconds"] || 0) > 0,
      do:
        "Goal achieved. Report final usage from this tool result's structured goal fields. If `goal.tokenBudget` is present, include token usage from `goal.tokensUsed` and `goal.tokenBudget`. If `goal.timeUsedSeconds` is greater than 0, summarize elapsed time in a concise, human-friendly form appropriate to the response language.",
      else: nil
  end

  defp completion_budget_report(_goal), do: nil
end
