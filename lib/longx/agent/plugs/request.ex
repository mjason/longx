defmodule Longx.Agent.Plugs.Request do
  @moduledoc """
  The last plug: turns the step into a Responses API request —
  instructions joined in order (the skills listed at the end), the
  transcript as `input`, the tools as `function` tools, the reasoning
  level when one is chosen, streaming on. `model` is the slug the person or
  a plug chose; nil is `longx`, the default model at the gateway.
  """

  use Longx.Agent.Plug

  @impl true
  def call(%Step{phase: phase} = step, _opts) when phase != :request, do: step

  def call(%Step{} = step, _opts) do
    tools = step.tools |> Map.values() |> Enum.sort_by(& &1.name)

    request =
      %{
        "model" => step.model || "longx",
        "instructions" => prompt(step),
        "input" => step.transcript,
        "tools" => Enum.map(tools, &Tool.to_responses/1) ++ step.raw_tools,
        # the grammar-constrained forms, for a provider that runs them
        # (Longx.Agent.Model swaps them in for OpenAI, drops them otherwise)
        "x-longx-custom-tools" => tools |> Enum.map(&Tool.to_custom/1) |> Enum.reject(&is_nil/1),
        "parallel_tool_calls" => true,
        "stream" => true,
        "store" => false,
        "client_metadata" => %{
          "thread_id" => step.thread_id,
          "turn_id" => step.turn_id,
          "x-codex-turn-metadata" => Jason.encode!(%{"request_kind" => "agent"})
        }
      }
      |> put_reasoning(step.effort)

    %{step | request: request}
  end

  defp prompt(%Step{instructions: texts, skills: skills}) do
    Enum.join(texts ++ skills_section(skills), "\n\n")
  end

  defp skills_section(skills) when map_size(skills) == 0, do: []

  defp skills_section(skills) do
    lines =
      skills
      |> Map.values()
      |> Enum.sort_by(& &1.name)
      |> Enum.map_join("\n", &"- #{&1.name}: #{&1.description}")

    ["# Skills\n\nThese skills are available; read one when it applies to the task:\n\n" <> lines]
  end

  defp put_reasoning(request, nil), do: request

  defp put_reasoning(request, effort),
    do: Map.put(request, "reasoning", %{"effort" => effort, "summary" => "auto"})
end
