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

  instructions """
  # Goals

  When the person asks for something to be pursued until done (not a single task), create a goal with `create_goal`: from then on every time you finish a turn without completing it, you are handed the objective again and continue. Call `update_goal` with `status: complete` when the objective is achieved, `blocked` (with a `reason`) when you cannot make progress without the person. Waiting on an agent you spawned is not blocked: end your turn, its report wakes you and the goal goes on. Do not create a goal for an ordinary request.
  """

  tool :create_goal,
       "Sets the thread's goal: an objective pursued across turns until you mark it complete." do
    param :objective, :string, "What done looks like, in one or two sentences", required: true
    param :token_budget, :integer, "Optional cap on tokens spent on the goal"
  end

  tool :update_goal, "Changes the goal's status or objective." do
    param :status, {:enum, ["active", "paused", "blocked", "complete"]}, "The new status"
    param :objective, :string, "A revised objective"

    param :reason,
          :string,
          "When blocked: what stands in the way, in one sentence (shown to the person)"
  end

  tool :get_goal, "Reads the current goal." do
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

  defp continuation(%{"objective" => objective}, round) do
    """
    （目标续跑）Your goal is still active (round #{round}): #{objective}

    Continue working toward it. When it is achieved, call update_goal with status "complete"; if you cannot make progress without the person, status "blocked". Otherwise take the next concrete step now.
    """
  end

  ## The tools

  def create_goal(%{"objective" => objective} = args, ctx) do
    attrs = %{
      "objective" => objective,
      "status" => "active",
      "tokenBudget" => args["token_budget"]
    }

    with {:ok, goal} <- Longx.Agent.set_goal(ctx.thread_id, attrs) do
      {:ok, "goal set: #{goal["objective"]} (active)"}
    end
  end

  def update_goal(args, ctx) do
    attrs =
      args
      |> Map.take(["status", "objective", "reason"])
      |> Enum.reject(&is_nil(elem(&1, 1)))
      |> Map.new()

    with {:ok, goal} <- Longx.Agent.set_goal(ctx.thread_id, attrs) do
      {:ok, "goal is now #{goal["status"]}: #{goal["objective"]}"}
    end
  end

  def get_goal(_args, ctx) do
    case Longx.Agent.get_goal(ctx.thread_id) do
      {:ok, nil} -> {:ok, "no goal is set"}
      {:ok, goal} -> {:ok, Jason.encode!(goal)}
    end
  end
end
