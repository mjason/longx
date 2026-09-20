defmodule Longx.Agent.Plugs.Environment do
  @moduledoc """
  Tells the model where it is, in codex's `<environment_context>` shape:
  the working directory, the shell its commands run in, today's date — and,
  ours, the operating system and the model this step runs on.
  """

  use Longx.Agent.Plug

  @impl true
  def call(%Step{phase: phase} = step, _opts) when phase != :request, do: step

  # codex's `<environment_context>` (core/src/context/world_state/environment.rs:
  # cwd, shell, current_date …), plus two elements of ours: the operating
  # system and what this step runs on (the kernel resolved it, so the agent
  # can say so instead of guessing from the model list)
  def call(%Step{cwd: cwd} = step, _opts) do
    {family, name} = :os.type()

    Step.instructions(
      step,
      "<environment_context>\n" <>
        element("cwd", cwd || File.cwd!()) <>
        element("shell", "bash") <>
        element("current_date", Date.to_iso8601(Date.utc_today())) <>
        element(
          "operating_system",
          "#{family} #{name}, #{:erlang.system_info(:system_architecture)}"
        ) <>
        model_element(step.assigns[:model_in_force]) <>
        "</environment_context>\n"
    )
  end

  defp element(name, value), do: "  <#{name}>#{escape(value)}</#{name}>\n"

  defp escape(text) when is_binary(text),
    do:
      text
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  defp escape(other), do: escape(to_string(other))

  defp model_element(%{slug: slug} = in_force) do
    named =
      case in_force[:name] do
        name when is_binary(name) and name != slug -> " (asked for as `#{name}`)"
        _ -> ""
      end

    effort =
      case in_force[:effort] do
        level when is_binary(level) -> " at reasoning effort `#{level}`"
        _ -> ""
      end

    element("model", "#{slug}#{named}#{effort}")
  end

  defp model_element(_), do: ""
end
