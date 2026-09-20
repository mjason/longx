defmodule Longx.System.Commands do
  @moduledoc """
  The commands the agents are running right now, for the settings page:
  what runs, for which session of which project, since when — and a way to
  kill one from the GUI when it hangs (a backtest that never ends, a shell
  loop nobody meant). The ledger is `Longx.System.Pressure.Registry`: every
  `exec_command` registers itself before the shim starts (with an `id`, the
  command, its thread, `started_at`) and the entry dies with the tool's
  process. `kill/1` tells that process `{:kill_command, :person}`; it kills
  its shim tree and reports to the model who ended the command.
  """

  alias Longx.Projects
  alias Longx.Projects.Thread
  alias Longx.System.Pressure

  @type session :: %{
          title: String.t(),
          slug: String.t(),
          thread_row_id: String.t(),
          root_row_id: String.t(),
          agent: String.t() | nil
        }

  @type command :: %{
          id: String.t(),
          cmd: String.t(),
          os_pid: pos_integer | nil,
          thread_id: String.t() | nil,
          session: session | nil,
          started_at: integer | nil,
          elapsed_ms: non_neg_integer | nil
        }

  @doc "Every live command, oldest first, with its session when the thread has a row."
  @spec list() :: [command]
  def list do
    now = System.system_time(:millisecond)

    Pressure.running()
    |> Enum.map(fn {_pid, entry} ->
      started = Map.get(entry, :started_at)

      %{
        id: Map.get(entry, :id),
        cmd: entry.cmd,
        os_pid: Map.get(entry, :os_pid),
        thread_id: entry.thread_id,
        session: session_of(entry.thread_id),
        started_at: started,
        elapsed_ms: if(is_integer(started), do: max(now - started, 0))
      }
    end)
    |> Enum.filter(&is_binary(&1.id))
    |> Enum.sort_by(&(&1.started_at || 0))
  end

  @doc "Kills the command with this id: its tool process is told, it ends the tree and reports."
  @spec kill(String.t()) :: :ok | {:error, :not_found}
  def kill(id) when is_binary(id) do
    case Enum.find(Pressure.running(), fn {_pid, entry} -> Map.get(entry, :id) == id end) do
      {pid, entry} ->
        Longx.System.Faults.record(
          :command,
          "exec_command",
          "killed from the settings page: `#{clip(entry.cmd)}`"
        )

        send(pid, {:kill_command, :person})
        # the entry goes with the process; a second kill of the same id finds nothing
        Registry.unregister_match(Pressure.registry(), :running, entry)
        :ok

      nil ->
        {:error, :not_found}
    end
  end

  defp clip(cmd) when byte_size(cmd) > 120, do: binary_part(cmd, 0, 120) <> "…"
  defp clip(cmd), do: cmd

  defp session_of(nil), do: nil

  defp session_of(kernel_thread_id) do
    case Projects.get_thread_by_kernel_id(kernel_thread_id, load: [:project]) do
      {:ok, %Thread{} = thread} ->
        root = root_row_id(thread)

        # a child's session is its parent's conversation, the child named beside it
        titled =
          case thread do
            %Thread{parent_thread_id: nil} -> thread
            %Thread{parent_thread_id: parent} -> Ash.get!(Thread, parent, load: [:project])
          end

        %{
          title: Projects.thread_label(titled),
          slug: thread.project.slug,
          thread_row_id: thread.id,
          root_row_id: root,
          agent: if(thread.parent_thread_id, do: Projects.agent_name(thread))
        }

      _ ->
        nil
    end
  end

  defp root_row_id(%Thread{parent_thread_id: nil, id: id}), do: id
  defp root_row_id(%Thread{parent_thread_id: parent}), do: parent
end
