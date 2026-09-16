defmodule LongxWeb.ProjectChannel do
  @moduledoc """
  `project:<id>` — what a project page needs besides thread streams:

    * `"changed"` — thread/turn rows changed (`Longx.Projects.broadcast_changed/1`); refetch
    * `"codex"` — `%{status: "ready" | "down"}` for the project's codex process
    * `"sample"` — the recycler's latest resource numbers for that process
  """

  use Phoenix.Channel

  alias Longx.Projects
  alias Phoenix.PubSub

  @impl true
  def join("project:" <> project_id, _payload, socket) do
    case Ash.get(Projects.Project, project_id) do
      {:ok, _project} ->
        :ok = PubSub.subscribe(Longx.PubSub, Projects.topic(project_id))
        :ok = PubSub.subscribe(Longx.PubSub, "codex:connection")
        {:ok, assign(socket, :project_id, project_id)}

      {:error, _} ->
        {:error, %{reason: "unknown project"}}
    end
  end

  @impl true
  def handle_info({:project_changed, _id}, socket) do
    push(socket, "changed", %{})
    {:noreply, socket}
  end

  def handle_info({:codex_connection, id, status}, %{assigns: %{project_id: id}} = socket) do
    push(socket, "codex", %{status: Atom.to_string(status)})
    {:noreply, socket}
  end

  def handle_info({:codex_sample, _id, measurements}, socket) do
    push(socket, "sample", measurements)
    {:noreply, socket}
  end

  # codex's fs/changed for the project root: the tree and git status are stale
  def handle_info({:files_changed, _id, paths}, socket) do
    push(socket, "files", %{paths: paths})
    {:noreply, socket}
  end

  # a config warning / deprecation notice from the project's codex
  def handle_info({:codex_notice, _id, notice}, socket) do
    push(socket, "notice", notice)
    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}
end
