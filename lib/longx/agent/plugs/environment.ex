defmodule Longx.Agent.Plugs.Environment do
  @moduledoc """
  Tells the model where it is: the working directory, the operating
  system and architecture, the shell its commands run in, today's date.
  """

  use Longx.Agent.Plug

  @impl true
  def call(%Step{phase: phase} = step, _opts) when phase != :request, do: step

  def call(%Step{cwd: cwd} = step, _opts) do
    {family, name} = :os.type()

    Step.instructions(step, """
    # Environment

    - Working directory: #{cwd || File.cwd!()}
    - Operating system: #{family} #{name}, #{:erlang.system_info(:system_architecture)}
    - Shell for commands: bash
    - Date: #{Date.to_iso8601(Date.utc_today())}#{model_line(step.assigns[:model_in_force])}
    """)
  end

  # what this step runs on (the kernel resolved it): the agent can say so
  # instead of guessing from the model list
  defp model_line(%{slug: slug} = in_force) do
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

    "\n- Model: you are running on model `#{slug}`#{named}#{effort}"
  end

  defp model_line(_), do: ""
end
