defmodule LongxWeb.Vite.Watcher do
  @moduledoc """
  The dev watcher that runs `npm run dev` (Vite) — through `Longx.Shim`, so
  the whole npm → node → vite tree dies with the BEAM. A plain
  `watchers: [npm: [...]]` leaves Vite alive on port 5173 after Phoenix is
  stopped (Vite does not exit when its stdin closes).

      config :longx, LongxWeb.Endpoint,
        watchers: [vite: {LongxWeb.Vite.Watcher, :run, [[cd: "assets"]]}]
  """

  alias Longx.Shim

  @doc "Runs Vite until it exits; output goes to this process's stdout."
  @spec run(keyword) :: :ok
  def run(opts \\ []) do
    cd = Keyword.get(opts, :cd, Path.expand("assets"))

    {:ok, shim} =
      Shim.start_link(["npm", "run", "dev"], cd: cd, stderr: :redirect_to_stdout, grace: 3_000)

    :ok = Shim.close_stdin(shim)
    pump(shim)
  end

  defp pump(shim) do
    case Shim.read(shim) do
      {:ok, data} ->
        IO.write(data)
        pump(shim)

      :eof ->
        _ = Shim.await_exit(shim, 5_000)
        :ok

      {:error, _} ->
        :ok
    end
  end
end
