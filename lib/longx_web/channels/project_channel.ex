defmodule LongxWeb.ProjectChannel do
  @moduledoc """
  `project:<id>` — what a project page needs besides thread streams:

    * `"changed"` — thread/turn rows changed (`Longx.Projects.broadcast_changed/1`); refetch
    * `"files"` — files changed under the root (`paths`, `[]` = everything): the
      tree and the git status are stale
    * `"git"` — HEAD, the index or a ref moved: the git window refetches
    * `"definition"` — the project's agent description changed (`.longx/agent.exs`,
      its plugs, roles, `local/`…): the page rereads it — whoever edited the file,
      an editor, the agent or the Files window; a new chat once ran with the
      description the page had loaded
    * `"watch"` — `%{watching, error}`: the file watcher's state
    * `"watches"` — the project's watches (Oban scripts) changed

  **The file watcher runs while a page is open** (`Longx.Projects.Watcher`): the
  channel subscribes after the join, monitors it and subscribes again a second
  after it dies; the last page leaving stops it. While it is not watching
  (no shim, a crash) the description is polled instead
  (`Longx.Agent.Definition.Loader.fingerprint/1`, a stat per file every
  `definition_poll_ms`, 2 s).
  """

  use Phoenix.Channel

  alias Longx.Projects
  alias Longx.Projects.Watcher

  @resubscribe_ms 1_000

  @impl true
  def join("project:" <> project_id, _payload, socket) do
    case Ash.get(Projects.Project, project_id) do
      {:ok, project} ->
        # no PubSub.subscribe: Phoenix subscribes a channel to its own topic, which is
        # Projects.topic/1 — a second subscription delivered every message twice
        send(self(), :watch)

        {:ok,
         socket
         |> assign(:project_id, project_id)
         |> assign(:root, project.root_path)
         |> assign(:watching, nil)
         |> assign(:watcher, nil)
         |> assign(:poll, nil)}

      {:error, _} ->
        {:error, %{reason: "unknown project"}}
    end
  end

  @impl true
  def handle_info(:watch, socket) do
    case Watcher.subscribe(socket.assigns.project_id, self()) do
      {:ok, pid, status} ->
        Process.monitor(pid)
        {:noreply, socket |> assign(:watcher, pid) |> watch_status(status)}

      {:error, reason} ->
        Process.send_after(self(), :watch, @resubscribe_ms)

        {:noreply,
         watch_status(socket, %{watching: false, error: "the file watcher: #{inspect(reason)}"})}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{assigns: %{watcher: pid}} = socket) do
    Process.send_after(self(), :watch, @resubscribe_ms)

    {:noreply,
     socket
     |> assign(:watcher, nil)
     |> watch_status(%{watching: false, error: "the file watcher stopped; starting it again"})}
  end

  def handle_info({:watch_status, _id, status}, socket),
    do: {:noreply, watch_status(socket, status)}

  def handle_info(:check_definition, %{assigns: %{watching: true}} = socket),
    do: {:noreply, assign(socket, :poll, nil)}

  def handle_info(:check_definition, socket) do
    {fingerprint, _} = socket.assigns.poll
    now = Longx.Agent.Definition.Loader.fingerprint(socket.assigns.root)
    if now != fingerprint, do: push(socket, "definition", %{})
    {:noreply, assign(socket, :poll, {now, schedule_definition_check()})}
  end

  def handle_info({:definition_changed, _id}, socket) do
    push(socket, "definition", %{})
    {:noreply, socket}
  end

  def handle_info({:git_changed, _id}, socket) do
    push(socket, "git", %{})
    {:noreply, socket}
  end

  def handle_info({:project_changed, _id}, socket) do
    push(socket, "changed", %{})
    {:noreply, socket}
  end

  # the project's watches changed (a run started or ended, a file came or went): refetch
  def handle_info({:watches_changed, _id}, socket) do
    push(socket, "watches", %{})
    {:noreply, socket}
  end

  def handle_info({:files_changed, _id, paths}, socket) do
    push(socket, "files", %{paths: paths})
    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # the poll runs exactly while nothing watches — its baseline taken before the page
  # is told, so nothing written after the page knows goes unseen
  defp watch_status(socket, %{watching: watching} = status) do
    socket =
      case {watching, socket.assigns.poll} do
        {false, nil} ->
          fingerprint = Longx.Agent.Definition.Loader.fingerprint(socket.assigns.root)
          assign(socket, :poll, {fingerprint, schedule_definition_check()})

        _ ->
          socket
      end

    payload = %{watching: watching, error: status[:error]}
    if payload != socket.assigns[:status], do: push(socket, "watch", payload)
    assign(socket, watching: watching, status: payload)
  end

  defp schedule_definition_check do
    ms =
      :longx
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:definition_poll_ms, 2_000)

    Process.send_after(self(), :check_definition, ms)
  end
end
