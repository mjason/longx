defmodule Longx.Codex.Worker do
  @moduledoc """
  One project's codex: a small supervisor around its `Longx.Codex.Connection`
  with its own restart budget (3 in 60 s). When that is exhausted this
  supervisor exits and `Longx.Codex.Pool` forgets it — only this project is
  affected, and the next `Pool.connection/1` starts it afresh.
  """

  use Supervisor

  @registry Longx.Codex.Registry

  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    Supervisor.start_link(__MODULE__, opts, name: via(project_id))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :project_id)},
      start: {__MODULE__, :start_link, [opts]},
      # a dead worker is not brought back by the pool; a caller does
      restart: :temporary,
      type: :supervisor,
      shutdown: 20_000
    }
  end

  @doc false
  def via(project_id), do: {:via, Registry, {@registry, {:worker, project_id}}}

  @impl true
  def init(opts) do
    project_id = Keyword.fetch!(opts, :project_id)

    connection_opts =
      Keyword.merge(
        [
          name: {:via, Registry, {@registry, {:connection, project_id}}},
          tag: project_id,
          home_dir: Keyword.fetch!(opts, :home_dir)
        ],
        Keyword.get(opts, :connection, [])
      )

    Supervisor.init([{Longx.Codex.Connection, connection_opts}],
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    )
  end
end
