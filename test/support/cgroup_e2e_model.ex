defmodule Longx.Test.CgroupE2EModel do
  @moduledoc """
  Local-only deterministic Responses SSE for the opt-in real cgroup E2E.
  No GraphQL, tool, shim, cgroup or resource report is mocked here.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%{method: "GET", request_path: "/identity"} = conn, opts) do
    case File.read(Keyword.fetch!(opts, :identity_path)) do
      {:ok, json} -> conn |> put_resp_content_type("application/json") |> send_resp(200, json)
      _ -> send_resp(conn, 503, "runner is not ready")
    end
  end

  def call(%{method: "POST", request_path: "/v1/responses"} = conn, opts) do
    with {:ok, body, conn} <- read_body(conn, length: 2_000_000),
         {:ok, request} <- Jason.decode(body),
         {:ok, result} <- plan(request, Keyword.fetch!(opts, :evidence_dir)) do
      chunks =
        case result do
          %{answer: answer} ->
            Longx.Test.ResponsesFixture.assistant_message(answer, model: "cgroup-e2e")

          %{tool: tool, arguments: arguments} ->
            Longx.Test.ResponsesFixture.function_call(tool, nil, arguments, model: "cgroup-e2e")
        end

      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

      Enum.reduce_while(chunks, conn, fn data, conn ->
        case chunk(conn, data) do
          {:ok, conn} -> {:cont, conn}
          {:error, _} -> {:halt, conn}
        end
      end)
    else
      _ -> send_resp(conn, 400, "only fixed cgroup E2E requests are accepted")
    end
  end

  def call(conn, _opts), do: send_resp(conn, 404, "not found")

  def plan(%{"model" => "cgroup-e2e", "input" => input}, evidence_dir) when is_list(input) do
    latest =
      input
      |> Enum.with_index()
      |> Enum.filter(fn {item, _} -> item["role"] == "user" end)
      |> List.last()

    with {item, index} <- latest,
         [_, kind, token] <-
           Regex.run(~r/\ACGROUP_E2E (exec|job) ([a-z0-9-]{1,64})\z/, text(item["content"])) do
      if input |> Enum.drop(index + 1) |> Enum.any?(&(&1["type"] == "function_call_output")) do
        {:ok, %{answer: "CGROUP_E2E_DONE #{token}"}}
      else
        command = payload(evidence_dir, token)

        case kind do
          "exec" ->
            {:ok,
             %{
               tool: "exec_command",
               arguments: %{
                 "cmd" => command,
                 "shell" => System.find_executable("sh"),
                 "login" => false,
                 "timeout_ms" => 40_000
               }
             }}

          "job" ->
            {:ok,
             %{
               tool: "start_job",
               arguments: %{"name" => token, "cmd" => command, "notify" => false}
             }}
        end
      end
    else
      _ -> {:error, :not_an_e2e_marker}
    end
  end

  def plan(_request, _evidence_dir), do: {:error, :not_the_local_test_model}

  defp text(content) when is_binary(content), do: content
  defp text(content) when is_list(content), do: Enum.map_join(content, &Map.get(&1, "text", ""))
  defp text(_), do: ""

  defp payload(dir, token) do
    membership = quote_path(Path.join(dir, "#{token}.membership"))
    started = quote_path(Path.join(dir, "#{token}.started"))
    release = quote_path(Path.join(dir, "#{token}.release"))

    """
    cat /proc/self/cgroup | tee #{membership}
    : > #{started}
    sleep 6
    cgroup_e2e_tick=6
    while [ ! -f #{release} ] && [ $cgroup_e2e_tick -lt 30 ]; do
      sleep 1
      cgroup_e2e_tick=$((cgroup_e2e_tick + 1))
    done
    if [ ! -f #{release} ]; then
      echo CGROUP_E2E_HOLD_TIMED_OUT
      exit 124
    fi
    echo CGROUP_E2E_PAYLOAD_DONE_#{token}
    """
  end

  defp quote_path(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"
end
