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
    - Date: #{Date.to_iso8601(Date.utc_today())}
    """)
  end
end
