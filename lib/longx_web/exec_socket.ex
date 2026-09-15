defmodule LongxWeb.ExecSocket do
  @moduledoc """
  The exec-server on the wire: codex connects here (the `url` in its
  `environments.toml`, one connection per codex process), one JSON-RPC
  message per WebSocket frame, and `Longx.Exec.Session` does the work.
  The socket process owns the session and the commands it starts; the
  connection closing takes them all down.

  codex sends no keepalives on a plain `ws://` environment, so the socket
  pings every 30 s itself — the pong keeps Bandit's idle timer at bay.
  """

  @behaviour WebSock

  alias Longx.Exec.Session

  require Logger

  @ping_every 30_000

  @impl true
  def init(%{project_id: project_id}) do
    Process.flag(:trap_exit, true)
    Process.send_after(self(), :ping, @ping_every)

    {:ok,
     %{
       session: Session.new(context: fn -> Longx.Projects.exec_context(project_id) end),
       project_id: project_id
     }}
  end

  @impl true
  def handle_in({text, [opcode: _]}, state) do
    case Jason.decode(text) do
      {:ok, message} ->
        {session, frames} = Session.handle(state.session, message)
        push(frames, %{state | session: session})

      {:error, _} ->
        Logger.warning("exec: malformed frame from codex (#{state.project_id})")

        push(
          [
            %{
              "id" => -1,
              "error" => %{"code" => -32600, "message" => "malformed JSON-RPC message"}
            }
          ],
          state
        )
    end
  end

  @impl true
  def handle_info(:ping, state) do
    Process.send_after(self(), :ping, @ping_every)
    {:push, {:ping, ""}, state}
  end

  def handle_info(message, state) do
    {session, frames} = Session.on_message(state.session, message)
    push(frames, %{state | session: session})
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug("exec: session for #{state.project_id} closed: #{inspect(reason)}")
    Session.close(state.session)
    :ok
  end

  defp push([], state), do: {:ok, state}
  defp push(frames, state), do: {:push, Enum.map(frames, &{:text, Jason.encode!(&1)}), state}
end
