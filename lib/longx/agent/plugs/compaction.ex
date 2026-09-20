defmodule Longx.Agent.Plugs.Compaction do
  @moduledoc """
  When to fold the context — the policy; the kernel does the folding
  (`{:compact, opts}` effect → a summary call in a task, a boundary in the
  transcript, the user's words kept verbatim; codex's shape and prompts).
  Asks for it when the context after the last step passed `at:` of the
  model's window (0.9, codex's default), when the provider refused the
  request for its length (`assigns.context_overflow`), or when asked —
  the model through `new_context_window`, the person through `/compact`.
  `get_context_remaining` is codex's other context tool.
  """

  use Longx.Agent.Plug

  @defaults [at: 0.9]

  tool :get_context_remaining, "Get the remaining tokens in the current context window." do
  end

  # codex's words (core/src/tools/handlers/new_context_window_spec.rs)
  tool :new_context_window,
       "Start a new context window. Does not clear, reset, or otherwise affect environment state." do
  end

  @impl true
  def init(opts), do: Keyword.merge(@defaults, opts)

  @impl true
  def call(%Step{phase: :request} = step, opts) do
    step = Longx.Agent.Plug.mount(step, __MODULE__)
    if wanted?(step, opts[:at]), do: Step.compact(step), else: step
  end

  def call(step, _opts), do: step

  defp wanted?(%Step{assigns: assigns} = step, at) do
    assigns[:context_overflow] == true or assigns[:compact_requested] == true or
      over?(step.usage.last, step.context_window, at)
  end

  defp over?(%{} = last, window, at) when is_integer(window) and window > 0,
    do: used(last) > window * at

  defp over?(_last, _window, _at), do: false

  defp used(last), do: (last["inputTokens"] || 0) + (last["outputTokens"] || 0)

  def get_context_remaining(_args, %{usage: %{last: %{} = last}, context_window: window})
      when is_integer(window) do
    {:ok, "#{max(window - used(last), 0)} tokens remain of a #{window}-token context window"}
  end

  def get_context_remaining(_args, _ctx), do: {:ok, "unknown: no usage has been reported yet"}

  def new_context_window(_args, _ctx) do
    {:ok,
     "a fresh context window starts before your next step; the conversation so far will be summarized",
     %{"compact" => true}}
  end
end
