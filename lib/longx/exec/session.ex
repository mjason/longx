defmodule Longx.Exec.Session do
  @moduledoc """
  One exec-server session: codex's side of `<CODEX_HOME>/environments.toml`
  connects to `LongxWeb.ExecSocket` and, over JSON-RPC (codex's dialect: no
  `jsonrpc` field), asks this module to run its commands and touch its
  files. The socket process owns the struct and calls `handle/2` for every
  frame; what can be answered at once comes back as frames, the rest
  (reads that wait, directory walks) runs under `Longx.Exec.TaskSupervisor`
  and arrives as `{:exec_out, frame}` messages; a command's events arrive
  as `{:exec_process, …}` and become frames with `event_frame/1`.

  Commands are `Longx.Exec.Process`es linked to the socket process, each
  wrapped by `Longx.Exec.Sandbox` from the request's `Longx.Exec.Policy`
  with the project's live options (`context:` — a function, read at every
  start, so a switch flipped in the settings holds from the next command).
  """

  alias Longx.Exec.{Discovery, Env, Fs, PathUri, Policy, Process, Sandbox}

  require Logger

  @enforce_keys [:context]
  defstruct [:context, :session_id, :shell, processes: %{}, handles: %{}, closing: %{}]

  @type t :: %__MODULE__{
          context: (-> %{sandbox: keyword, shim: keyword}),
          session_id: String.t() | nil,
          shell: {String.t(), Path.t()} | nil,
          processes: %{String.t() => pid},
          handles: %{String.t() => Path.t()},
          closing: %{String.t() => true}
        }

  @type frame :: map

  @method_not_found -32601
  @invalid_params -32602
  @invalid_request -32600
  @internal -32603

  @doc "A session; `context:` gives the sandbox / shim options for each start."
  @spec new(keyword) :: t
  def new(opts) do
    %__MODULE__{
      context: Keyword.get(opts, :context, fn -> %{sandbox: [], shim: []} end),
      shell: shell()
    }
  end

  @doc "How many commands the session still holds."
  @spec process_count(t) :: non_neg_integer
  def process_count(%__MODULE__{processes: processes}), do: map_size(processes)

  @doc "A codex event as the notification frame it goes out as."
  @spec event_frame({:exec_process, String.t(), String.t(), map}) :: frame
  def event_frame({:exec_process, _id, method, params}),
    do: %{"method" => method, "params" => params}

  @doc """
  Handles one frame from codex: the session after it and the frames to send
  back now. Must run in the socket process (commands are linked to it).
  """
  @spec handle(t, map) :: {t, [frame]}
  def handle(session, %{"id" => id, "method" => method} = message) do
    params = message["params"] || %{}

    case request(session, method, params, id) do
      {:reply, result, session} ->
        {session, [%{"id" => id, "result" => result}]}

      {:error, {code, text}, session} ->
        {session, [%{"id" => id, "error" => %{"code" => code, "message" => text}}]}

      {:async, session} ->
        {session, []}
    end
  end

  def handle(session, %{"method" => "initialized"}), do: {session, []}

  def handle(session, %{"method" => method}) do
    Logger.debug("exec: ignoring notification #{method}")
    {session, []}
  end

  def handle(session, other) do
    Logger.warning("exec: ignoring frame #{inspect(other) |> String.slice(0, 200)}")
    {session, []}
  end

  @doc "A frame arriving from a task or a command, translated for the socket."
  @spec on_message(t, term) :: {t, [frame]}
  def on_message(session, {:exec_out, frame}), do: {session, [frame]}

  def on_message(session, {:exec_process, id, "process/closed", _} = event) do
    # a process codex already terminated is done once it closes
    session =
      if Map.has_key?(session.closing, id),
        do: drop_process(session, id),
        else: session

    {session, [event_frame(event)]}
  end

  def on_message(session, {:exec_process, _, _, _} = event), do: {session, [event_frame(event)]}

  def on_message(session, {:EXIT, pid, reason}) do
    case Enum.find(session.processes, fn {_, p} -> p == pid end) do
      {id, _} ->
        if reason not in [:normal, :shutdown],
          do: Logger.warning("exec: process #{id} died: #{inspect(reason)}")

        {%{
           session
           | processes: Map.delete(session.processes, id),
             closing: Map.delete(session.closing, id)
         }, []}

      nil ->
        {session, []}
    end
  end

  def on_message(session, _other), do: {session, []}

  @doc "Ends the session: every command still running is taken down."
  @spec close(t) :: :ok
  def close(%__MODULE__{processes: processes}) do
    for {_, pid} <- processes, do: GenServer.stop(pid, :shutdown, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  ## requests

  defp request(session, "initialize", params, _id) do
    session_id = session.session_id || params["resumeSessionId"] || Ecto.UUID.generate()
    session = %{session | session_id: session_id}

    {:reply, %{"sessionId" => session_id, "environmentInfo" => environment_info(session)},
     session}
  end

  defp request(session, "environment/info", _params, _id),
    do: {:reply, environment_info(session), session}

  defp request(session, "environment/status", _params, _id),
    do: {:reply, %{"status" => "ready"}, session}

  defp request(session, "process/start", params, _id) do
    Logger.debug(fn ->
      "exec: start #{params["processId"]} #{inspect(params["argv"])} sandbox=#{Jason.encode!(params["sandbox"])}"
    end)

    with {:ok, spec} <- start_spec(session, params) do
      case Process.start_link(spec) do
        {:ok, pid} ->
          id = spec[:id]

          {:reply, %{"processId" => id, "sandboxType" => Sandbox.wire_name(spec[:sandbox])},
           %{session | processes: Map.put(session.processes, id, pid)}}

        {:error, {:start_failed, reason}} ->
          {:error,
           {@internal, "failed to start #{Enum.join(params["argv"], " ")}: #{inspect(reason)}"},
           session}

        {:error, reason} ->
          {:error, {@internal, inspect(reason)}, session}
      end
    end
  end

  defp request(session, "process/read", params, id) do
    case Map.fetch(session.processes, params["processId"] || "") do
      {:ok, pid} ->
        async(id, session, fn ->
          Process.read(pid, params["afterSeq"] || 0, params["maxBytes"], params["waitMs"] || 0)
        end)

      :error ->
        async(id, session, fn ->
          {:error, {@invalid_request, "unknown process id #{params["processId"]}"}}
        end)
    end
  end

  defp request(session, "process/write", params, _id) do
    with {:ok, chunk} <- base64(params["chunk"]),
         {:ok, write_id} <- string(params["writeId"], "writeId") do
      status =
        case Map.fetch(session.processes, params["processId"] || "") do
          {:ok, pid} ->
            case Process.write(pid, chunk, write_id) do
              :accepted -> "accepted"
              :stdin_closed -> "stdinClosed"
            end

          :error ->
            "unknownProcess"
        end

      {:reply, %{"status" => status}, session}
    end
  end

  defp request(session, "process/signal", params, _id) do
    with {:ok, pid} <- Map.fetch(session.processes, params["processId"] || ""),
         "interrupt" <- params["signal"] do
      Process.signal(pid, :interrupt)
    end

    {:reply, %{}, session}
  end

  defp request(session, "process/terminate", params, _id) do
    id = params["processId"] || ""

    case Map.fetch(session.processes, id) do
      {:ok, pid} ->
        if Process.terminate(pid) do
          {:reply, %{"running" => true}, %{session | closing: Map.put(session.closing, id, true)}}
        else
          {:reply, %{"running" => false}, drop_process(session, id)}
        end

      :error ->
        {:reply, %{"running" => false}, session}
    end
  end

  defp request(session, "fs/open", params, _id) do
    with {:ok, handle_id} <- string(params["handleId"], "handleId"),
         {:ok, policy} <- policy(params["sandbox"]),
         {:ok, path} <- Fs.allowed(policy, params["path"], :read),
         {:ok, %{type: :regular}} <- File.stat(path) |> stat_error(path) do
      {:reply, %{"handleId" => handle_id},
       %{session | handles: Map.put(session.handles, handle_id, path)}}
    else
      {:ok, %{type: _}} -> {:error, {@invalid_request, "not a regular file"}, session}
      error -> error(error, session)
    end
  end

  defp request(session, "fs/readBlock", params, id) do
    case Map.fetch(session.handles, params["handleId"] || "") do
      {:ok, path} ->
        offset = params["offset"] || 0
        len = params["len"] || 0

        async(id, session, fn ->
          with {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
            result =
              case :file.pread(file, offset, max(len, 1)) do
                {:ok, data} ->
                  {:ok,
                   %{
                     "chunk" => Base.encode64(binary_part(data, 0, min(byte_size(data), len))),
                     "eof" => byte_size(data) < len
                   }}

                :eof ->
                  {:ok, %{"chunk" => "", "eof" => true}}

                {:error, reason} ->
                  {:error, {@internal, "#{path}: #{inspect(reason)}"}}
              end

            File.close(file)
            result
          else
            {:error, reason} -> {:error, {@internal, "#{path}: #{inspect(reason)}"}}
          end
        end)

      :error ->
        {:error, {@invalid_request, "unknown file handle"}, session}
    end
  end

  defp request(session, "fs/close", params, _id),
    do: {:reply, %{}, %{session | handles: Map.delete(session.handles, params["handleId"] || "")}}

  defp request(session, "fs/" <> op, params, id) do
    case policy(params["sandbox"]) do
      {:ok, policy} -> async(id, session, fn -> fs(op, policy, params) end)
      {:error, _} = error -> error(error, session)
    end
  end

  defp request(session, "capabilityRoots/discoverV1", params, id) do
    roots = params["roots"] || []

    async(id, session, fn ->
      discoveries =
        Enum.flat_map(roots, fn root ->
          case policy(root["sandbox"]) do
            {:ok, policy} ->
              Discovery.discover(policy, [root])["roots"]

            {:error, {_, message}} ->
              [
                %{
                  "id" => root["id"],
                  "path" => root["path"],
                  "skills" => [],
                  "namespaceManifests" => [],
                  "warnings" => [],
                  "error" => message
                }
              ]
          end
        end)

      {:ok, %{"roots" => discoveries}}
    end)
  end

  defp request(session, method, _params, _id),
    do: {:error, {@method_not_found, "method not found: #{method}"}, session}

  defp fs("readFile", policy, p), do: Fs.read_file(policy, p["path"])
  defp fs("writeFile", policy, p), do: Fs.write_file(policy, p["path"], p["dataBase64"])

  defp fs("createDirectory", policy, p),
    do: Fs.create_directory(policy, p["path"], p["recursive"] || false)

  defp fs("getMetadata", policy, p),
    do: Fs.get_metadata(policy, p["path"], p["followSymlinks"] || false)

  defp fs("canonicalize", policy, p), do: Fs.canonicalize(policy, p["path"])
  defp fs("readDirectory", policy, p), do: Fs.read_directory(policy, p["path"])
  defp fs("walk", policy, p), do: Fs.walk(policy, p["path"], p["options"] || %{})

  defp fs("remove", policy, p),
    do: Fs.remove(policy, p["path"], p["recursive"] || false, p["force"] || false)

  defp fs("copy", policy, p),
    do: Fs.copy(policy, p["sourcePath"], p["destinationPath"], p["recursive"] || false)

  defp fs(op, _policy, _p), do: {:error, {@method_not_found, "method not found: fs/#{op}"}}

  # the process spec of a process/start request
  defp start_spec(session, params) do
    with {:ok, argv} <- argv(params["argv"]),
         {:ok, cwd} <- PathUri.to_path(params["cwd"]) |> wrap(@invalid_params),
         true <- File.dir?(cwd) || {:error, {@invalid_params, "cwd does not exist: #{cwd}"}},
         {:ok, id} <- string(params["processId"], "processId"),
         {:ok, policy} <- policy(params["sandbox"]),
         context = session.context.(),
         {:ok, {kind, wrapped}} <- Sandbox.wrap(policy, argv, context.sandbox) |> wrap_sandbox() do
      {:ok,
       [
         id: id,
         argv: wrapped,
         cwd: cwd,
         env:
           Env.build(System.get_env(), params["envPolicy"], params["env"] || %{},
             tool_bin: Longx.Codex.Home.tool_bin()
           ),
         tty: params["tty"] || false,
         pipe_stdin: params["pipeStdin"] || false,
         sandbox: kind,
         notify: self(),
         shim: context.shim
       ]}
    else
      {:error, _} = error -> error(error, session)
    end
  end

  defp argv([program | _] = argv) when is_binary(program) and program != "", do: {:ok, argv}
  defp argv(_), do: {:error, {@invalid_params, "argv must name a program"}}

  defp wrap({:ok, value}, _code), do: {:ok, value}
  defp wrap({:error, message}, code), do: {:error, {code, message}}

  defp wrap_sandbox({:ok, wrapped}), do: {:ok, wrapped}

  defp wrap_sandbox({:error, :no_bwrap}),
    do:
      {:error,
       {@internal, "sandbox unavailable: bubblewrap is not installed (see Settings → 沙箱)"}}

  defp wrap_sandbox({:error, :unsupported}),
    do: {:error, {@internal, "sandbox unavailable on this platform"}}

  defp policy(context), do: Policy.parse(context, []) |> wrap(@invalid_params)

  defp base64(nil), do: {:ok, ""}

  defp base64(text) do
    case Base.decode64(text) do
      {:ok, data} -> {:ok, data}
      :error -> {:error, {@invalid_params, "chunk is not valid base64"}}
    end
  end

  defp string(value, _name) when is_binary(value) and value != "", do: {:ok, value}
  defp string(_value, name), do: {:error, {@invalid_params, "#{name} must be a non-empty string"}}

  defp stat_error({:ok, stat}, _path), do: {:ok, stat}
  defp stat_error({:error, :enoent}, path), do: {:error, {-32004, "#{path}: no such file"}}

  defp stat_error({:error, reason}, path),
    do: {:error, {@invalid_request, "#{path}: #{inspect(reason)}"}}

  defp error({:error, {code, message}}, session), do: {:error, {code, message}, session}

  # answer later, from a task, as an {:exec_out, frame} message to the socket
  defp async(id, session, fun) do
    socket = self()

    Task.Supervisor.start_child(Longx.Exec.TaskSupervisor, fn ->
      frame =
        case fun.() do
          {:ok, result} ->
            %{"id" => id, "result" => result}

          {:error, {code, message}} ->
            %{"id" => id, "error" => %{"code" => code, "message" => message}}
        end

      send(socket, {:exec_out, frame})
    end)

    {:async, session}
  end

  defp drop_process(session, id) do
    case Map.pop(session.processes, id) do
      {nil, _} ->
        session

      {pid, processes} ->
        GenServer.stop(pid, :normal, 1_000)
        %{session | processes: processes, closing: Map.delete(session.closing, id)}
    end
  catch
    :exit, _ ->
      %{
        session
        | processes: Map.delete(session.processes, id),
          closing: Map.delete(session.closing, id)
      }
  end

  ## environment

  defp environment_info(session) do
    {name, path} = session.shell
    tmp = System.get_env("TMPDIR")

    %{
      "shell" => %{"name" => name, "path" => path},
      "executorVersion" => "longx-#{Application.spec(:longx, :vsn)}",
      "cwd" => nil,
      "userHomeDir" => PathUri.from_path(System.user_home!()),
      "platformOs" => platform_os(),
      "temporaryDirectories" =>
        if(tmp && tmp != "", do: [PathUri.from_path(Path.expand(tmp))], else: []),
      "tempDir" => PathUri.from_path(System.tmp_dir!()),
      "capabilities" => %{
        "networkProxyLaunch" => false,
        "capabilityDiscoverySandbox" => false,
        "environmentConfigRead" => false,
        "httpHeaderEnvVars" => false,
        "sandboxedFileStreaming" => false,
        "shellSnapshotV2" => false
      }
    }
  end

  defp platform_os do
    case Longx.Platform.current() do
      {:darwin, _} -> "macos"
      {os, _} -> Atom.to_string(os)
    end
  end

  # the user's shell when codex can drive it (`-lc`), bash / zsh / sh otherwise
  defp shell do
    candidates =
      [
        System.get_env("SHELL"),
        "/bin/zsh",
        "/bin/bash",
        "/bin/sh",
        "/usr/bin/zsh",
        "/usr/bin/bash"
      ]
      |> Enum.reject(&is_nil/1)

    Enum.find_value(candidates, {"sh", "/bin/sh"}, fn path ->
      name = Path.basename(path)
      if name in ["bash", "zsh", "sh"] and File.exists?(path), do: {name, path}
    end)
  end
end
