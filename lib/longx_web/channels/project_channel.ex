defmodule LongxWeb.ProjectChannel do
  @moduledoc """
  `project:<id>` — what a project page needs besides thread streams:

    * `"changed"` — thread/turn rows changed (`Longx.Projects.broadcast_changed/1`); refetch
    * `"files"` — files changed under the root (`Longx.Projects.broadcast_files_changed/2`)
  """

  use Phoenix.Channel

  alias Longx.Projects
  alias Phoenix.PubSub

  @impl true
  def join("project:" <> project_id, _payload, socket) do
    case Ash.get(Projects.Project, project_id) do
      {:ok, _project} ->
        :ok = PubSub.subscribe(Longx.PubSub, Projects.topic(project_id))
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

  # files changed under the project root: the tree and git status are stale
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
end
