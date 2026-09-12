defmodule Longx.Codex.Tool.Runner do
  @moduledoc """
  Executes one `item/tool/call` from codex and produces its
  `DynamicToolCallResponse` (`%{"contentItems" => [...], "success" => bool}`).

  The pipeline, in order — every step's failure is a *failed tool call the
  model can read*, never a JSON-RPC error and never a crash of the caller:

    1. look the tool up by `{namespace, name}` (`namespace` defaults to `builtin`)
    2. validate `arguments` against the tool's `input_schema/0`; on mismatch the
       model gets the exact JSON-pointer errors plus the schema, so it can
       correct itself instead of retrying blindly
    3. build the `Longx.Codex.Tool.Context`
    4. run `call/2` in a supervised task under the tool's `timeout/0`
    5. normalise the result into content items

  Emits `[:longx, :codex, :tool, :start | :stop | :exception]` telemetry.
  """

  alias Longx.Codex.{ThreadState, Tool}
  alias Longx.Codex.Tool.{Context, Registry}

  @task_supervisor Longx.Codex.TaskSupervisor

  @type response :: %{required(String.t()) => term}

  @spec run(map) :: response
  def run(%{"tool" => name} = params) do
    namespace = params["namespace"] || Tool.default_namespace()

    case Registry.fetch(namespace, name) do
      {:ok, tool} -> run_tool(tool, params)
      :error -> failure("unknown tool #{namespace}.#{name}. Available tools: #{available()}")
    end
  end

  def run(_params), do: failure("malformed tool call: missing \"tool\"")

  defp run_tool(tool, params) do
    meta = %{
      namespace: tool.namespace,
      name: tool.name,
      thread_id: params["threadId"],
      call_id: params["callId"]
    }

    :telemetry.span([:longx, :codex, :tool], meta, fn ->
      response =
        case validate(tool, params["arguments"]) do
          :ok -> execute(tool, params["arguments"], context(params))
          {:error, message} -> failure(message)
        end

      {response, Map.put(meta, :success, response["success"])}
    end)
  end

  ## validation

  defp validate(tool, arguments) when is_map(arguments) do
    case ExJsonSchema.Validator.validate(tool.schema, arguments) do
      :ok ->
        :ok

      {:error, errors} ->
        details = Enum.map_join(errors, "\n", fn {message, path} -> "  #{path}: #{message}" end)
        {:error, invalid_arguments(tool, details)}
    end
  end

  defp validate(tool, arguments),
    do: {:error, invalid_arguments(tool, "  expected a JSON object, got #{inspect(arguments)}")}

  defp invalid_arguments(tool, details) do
    "invalid arguments for #{tool.namespace}.#{tool.name}:\n#{details}\nThe arguments must match this JSON schema:\n#{Jason.encode!(tool.input_schema)}"
  end

  ## context

  defp context(params) do
    thread_id = params["threadId"]

    %Context{
      thread_id: thread_id,
      turn_id: params["turnId"],
      call_id: params["callId"],
      cwd: cwd(thread_id),
      snapshot: fn -> ThreadState.snapshot(thread_id) end
    }
  end

  defp cwd(nil), do: nil
  defp cwd(thread_id), do: get_in(ThreadState.snapshot(thread_id), [:thread, "cwd"])

  ## execution

  defp execute(tool, arguments, ctx) do
    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn -> tool.module.call(arguments, ctx) end)

    case Task.yield(task, tool.timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, content}} ->
        success(content)

      {:ok, {:error, message}} when is_binary(message) ->
        failure(message)

      {:ok, other} ->
        failure("#{tool.namespace}.#{tool.name} returned an unexpected value: #{inspect(other)}")

      {:exit, {exception, _stack}} when is_exception(exception) ->
        failure("#{tool.namespace}.#{tool.name} crashed: #{Exception.message(exception)}")

      {:exit, reason} ->
        failure("#{tool.namespace}.#{tool.name} crashed: #{inspect(reason)}")

      nil ->
        failure("#{tool.namespace}.#{tool.name} timed out after #{tool.timeout}ms")
    end
  end

  ## responses

  defp success(text) when is_binary(text),
    do: %{"success" => true, "contentItems" => [text_item(text)]}

  defp success(content) when is_list(content),
    do: %{"success" => true, "contentItems" => Enum.map(content, &content_item/1)}

  defp failure(message), do: %{"success" => false, "contentItems" => [text_item(message)]}

  defp content_item({:text, text}), do: text_item(text)
  defp content_item({:image_url, url}), do: %{"type" => "inputImage", "imageUrl" => url}

  defp text_item(text), do: %{"type" => "inputText", "text" => text}

  defp available, do: Registry.all() |> Enum.map_join(", ", &"#{&1.namespace}.#{&1.name}")
end
