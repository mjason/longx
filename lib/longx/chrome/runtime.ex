defmodule Longx.Chrome.Runtime do
  @moduledoc """
  A browser session's JavaScript runtime: one `shim js` process (goja, one
  persistent realm — `native/shim/js.go`) under `Longx.Shim`, spoken to in
  JSON lines. `execute/4` runs a cell and answers with its value, console
  output, screenshots and error; the cell's host calls (`__longx_cdp`) go to
  the `cdp:` function this runtime was started with (the session's CDP
  proxy) as `%{target, method, params, runtime}`, each in a task of its own;
  the function answers `{:ok, value}` or `{:error, message}`.

  The deadline is the cell's: the shim interrupts the cell itself at
  `timeout_ms` and rebuilds its realm (`reset: true` — the state is gone,
  the prelude is back); a shim that does not answer within a grace after
  that is killed and started again for the next cell. A cell that finds the
  shim gone (a crash, a kill) gets a fresh one and `reset: true`.
  """

  use GenServer, restart: :temporary

  alias Longx.Shim

  @grace_ms 2_000
  @read_chunk 1_048_576

  @type result :: %{
          value: term,
          output: String.t(),
          images: [%{mime: String.t(), data: String.t()}],
          error: String.t() | nil,
          interrupted: boolean,
          reset: boolean
        }

  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Runs a cell. `emit:` gets each console line as it comes. The call waits
  `timeout_ms` plus the shim's grace.
  """
  @spec execute(GenServer.server(), String.t(), pos_integer, keyword) ::
          {:ok, result} | {:error, term}
  def execute(rt, code, timeout_ms, opts \\ []) when is_binary(code) and is_integer(timeout_ms) do
    GenServer.call(
      rt,
      {:execute, code, timeout_ms, Keyword.get(opts, :emit)},
      timeout_ms + @grace_ms + 10_000
    )
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc "Stops the runtime and its shim."
  def stop(rt), do: GenServer.stop(rt, :normal)

  @doc """
  The running cell waits on something outside the browser (an ask put to the
  person, say): its deadline stops — the shim's and ours — until `resume/1`.
  Nothing in the shipped session holds today (the per-origin ask that did is
  gone); the runtime keeps the capability for a plug that needs it.
  """
  def hold(rt), do: GenServer.cast(rt, :hold)
  def resume(rt), do: GenServer.cast(rt, :resume)

  @doc false
  def kill_for_test(rt), do: GenServer.call(rt, :kill_for_test)

  ## GenServer

  defstruct prelude: "",
            cdp: nil,
            shim: nil,
            reader: nil,
            buffer: "",
            ready?: false,
            reset?: false,
            next: 0,
            # the running cell
            cell: nil

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      prelude: Keyword.get(opts, :prelude, "") || "",
      cdp: Keyword.fetch!(opts, :cdp)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:execute, _code, _timeout, _emit}, _from, %{cell: %{}} = state),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:execute, code, timeout_ms, emit}, from, state) do
    case ensure_shim(state) do
      {:ok, state} ->
        id = "c#{state.next + 1}"

        cell = %{
          id: id,
          from: from,
          output: [],
          images: [],
          emit: emit,
          timeout_ms: timeout_ms,
          deadline: Process.send_after(self(), {:deadline, id}, timeout_ms + @grace_ms),
          reset?: state.reset?
        }

        case write(state, %{
               "type" => "execute",
               "id" => id,
               "code" => code,
               "timeout_ms" => timeout_ms
             }) do
          :ok ->
            {:noreply, %{state | next: state.next + 1, cell: cell, reset?: false}}

          {:error, reason} ->
            cancel(cell.deadline)
            {:reply, {:error, reason}, shim_gone(state)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:kill_for_test, _from, state) do
    if state.shim, do: Shim.kill(state.shim, 100)
    {:reply, :ok, shim_gone(state)}
  end

  @impl true
  def handle_cast(:hold, %{cell: %{deadline: timer} = cell} = state) when timer != nil do
    Process.cancel_timer(timer)
    _ = write(state, %{"type" => "hold", "id" => cell.id})
    {:noreply, %{state | cell: %{cell | deadline: nil}}}
  end

  def handle_cast(:resume, %{cell: %{deadline: nil} = cell} = state) do
    _ = write(state, %{"type" => "resume", "id" => cell.id, "timeout_ms" => cell.timeout_ms})
    deadline = Process.send_after(self(), {:deadline, cell.id}, cell.timeout_ms + @grace_ms)
    {:noreply, %{state | cell: %{cell | deadline: deadline}}}
  end

  def handle_cast(hold_or_resume, state) when hold_or_resume in [:hold, :resume],
    do: {:noreply, state}

  def handle_cast({:cdp_result, id, result}, state) do
    line =
      case result do
        {:ok, value} -> %{"type" => "cdp_result", "id" => id, "result" => value}
        {:error, message} -> %{"type" => "cdp_result", "id" => id, "error" => to_string(message)}
      end

    _ = write(state, line)
    {:noreply, state}
  end

  @impl true
  def handle_info({:line, json}, state) do
    case Jason.decode(json) do
      {:ok, %{"type" => type} = line} -> {:noreply, handle_line(type, line, state)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:deadline, id}, %{cell: %{id: id} = cell} = state) do
    # the shim did not stop the cell in time (a native call it cannot
    # interrupt): kill it, the next cell gets a fresh one
    if state.shim, do: Shim.kill(state.shim, 500)

    reply(cell, %{
      value: nil,
      error:
        "the cell did not stop at its deadline; the runtime was killed and its state is lost",
      interrupted: true,
      reset: true
    })

    {:noreply, %{shim_gone(state) | cell: nil}}
  end

  def handle_info({:deadline, _stale}, state), do: {:noreply, state}

  def handle_info({:shim_eof, reader}, %{reader: reader} = state), do: {:noreply, lost(state)}
  def handle_info({:shim_eof, _old}, state), do: {:noreply, state}

  def handle_info({:EXIT, shim, _reason}, %{shim: shim} = state), do: {:noreply, lost(state)}
  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # the reader first: it sits in a read of the shim we are about to stop
    if state.reader, do: Process.exit(state.reader, :kill)

    if state.shim do
      _ = write(state, %{"type" => "close"})
      Shim.kill(state.shim, 500)
    end

    :ok
  end

  ## Lines from the shim

  defp handle_line("ready", _line, state), do: %{state | ready?: true}

  defp handle_line("log", %{"text" => text}, %{cell: %{} = cell} = state) do
    text = text <> "\n"
    if is_function(cell.emit, 1), do: cell.emit.(text)
    %{state | cell: %{cell | output: [cell.output, text]}}
  end

  defp handle_line("image", %{"mime" => mime, "data" => data}, %{cell: %{} = cell} = state),
    do: %{state | cell: %{cell | images: cell.images ++ [%{mime: mime, data: data}]}}

  defp handle_line("cdp", %{"id" => id, "target" => target, "method" => method} = line, state) do
    params = Map.get(line, "params") || %{}
    me = self()
    cdp = state.cdp
    call = %{target: target, method: method, params: params, runtime: me}

    Task.Supervisor.start_child(Longx.Chrome.TaskSupervisor, fn ->
      result =
        try do
          case cdp.(call) do
            {:ok, value} -> {:ok, value}
            {:error, reason} when is_binary(reason) -> {:error, reason}
            {:error, reason} -> {:error, inspect(reason)}
            other -> {:error, "bad cdp answer: #{inspect(other)}"}
          end
        rescue
          e -> {:error, Exception.message(e)}
        end

      GenServer.cast(me, {:cdp_result, id, result})
    end)

    state
  end

  defp handle_line("result", %{"id" => id} = line, %{cell: %{id: id} = cell} = state) do
    cancel(cell.deadline)

    reply(cell, %{
      value: Map.get(line, "value"),
      error: Map.get(line, "error"),
      interrupted: Map.get(line, "interrupted", false) == true,
      reset: Map.get(line, "reset", false) == true
    })

    %{state | cell: nil}
  end

  defp handle_line("error", %{"error" => message}, %{cell: %{} = cell} = state) do
    cancel(cell.deadline)
    reply(cell, %{value: nil, error: message, interrupted: false, reset: false})
    %{state | cell: nil}
  end

  defp handle_line(_type, _line, state), do: state

  defp reply(cell, result) do
    GenServer.reply(
      cell.from,
      {:ok,
       Map.merge(result, %{
         output: IO.iodata_to_binary(cell.output),
         images: cell.images,
         reset: result.reset or cell.reset?
       })}
    )
  end

  ## The shim

  defp ensure_shim(%{shim: nil} = state) do
    with {:ok, shim} <- Shim.start_link([Shim.executable(), "js"], stderr: :disable),
         :ok <-
           Shim.write(
             shim,
             Jason.encode!(%{"type" => "init", "prelude" => state.prelude}) <> "\n"
           ) do
      me = self()
      {:ok, reader} = Task.start_link(fn -> read_loop(shim, me, "") end)
      {:ok, %{state | shim: shim, reader: reader, ready?: false}}
    else
      {:error, reason} -> {:error, {:shim, reason}}
    end
  end

  defp ensure_shim(state), do: {:ok, state}

  # the shim's stdout, a line at a time, to the runtime
  defp read_loop(shim, owner, buffer) do
    case read(shim) do
      {:ok, data} ->
        {lines, rest} = split_lines(buffer <> data)
        Enum.each(lines, &send(owner, {:line, &1}))
        read_loop(shim, owner, rest)

      _eof_or_error ->
        send(owner, {:shim_eof, self()})
    end
  end

  # the shim stopping under a read is the end of the stream, not a crash
  defp read(shim) do
    Shim.read(shim, @read_chunk, :infinity)
  catch
    :exit, _ -> :eof
  end

  defp split_lines(data) do
    parts = String.split(data, "\n")
    {lines, [rest]} = Enum.split(parts, length(parts) - 1)
    {Enum.reject(lines, &(&1 == "")), rest}
  end

  defp write(%{shim: nil}, _line), do: {:error, :closed}

  defp write(%{shim: shim}, line) do
    Shim.write(shim, Jason.encode!(line) <> "\n")
  catch
    :exit, _ -> {:error, :closed}
  end

  # the shim is gone: a running cell fails, the next one starts a fresh shim
  defp lost(%{cell: %{} = cell} = state) do
    cancel(cell.deadline)

    reply(cell, %{
      value: nil,
      error: "the JavaScript runtime exited; its state is lost",
      interrupted: false,
      reset: true
    })

    %{shim_gone(state) | cell: nil}
  end

  defp lost(state), do: shim_gone(state)

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)

  defp shim_gone(state) do
    if state.reader, do: Process.exit(state.reader, :kill)
    %{state | shim: nil, reader: nil, ready?: false, reset?: true}
  end
end
