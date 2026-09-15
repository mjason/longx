defmodule Longx.Codex.ServerRequest do
  @moduledoc """
  How `Longx.Codex.Connection` answers requests the app-server sends *to us*
  (approvals, user-input questions, MCP elicitations, dynamic tool calls…).

  A handler returns one of:

    * `{:reply, result}` — answer now
    * `{:error, code, message}` — refuse now
    * `{:defer, timeout_ms, fallback}` — the answer comes later through
      `Longx.Codex.Connection.respond/3` (typically from the UI); if nobody
      answers within `timeout_ms` the connection sends `fallback`
      (`{:reply, result}` or `{:error, code, message}`) so the turn never
      hangs forever
    * `{:async, fun, timeout_ms, fallback}` — the connection runs `fun/0` in a
      supervised task and sends what it returns (a `{:reply, _}` /
      `{:error, _, _}`); a crash or a timeout sends `fallback`. For work that
      needs no human (dynamic tool calls) but must not block the connection

  Configure with `config :longx, Longx.Codex.Connection, server_request_handler: Mod`;
  the default is `Longx.Codex.ServerRequest.Default`.
  """

  @type reply :: {:reply, map} | {:error, integer, String.t()}
  @type outcome :: reply | {:defer, pos_integer, reply} | {:async, (-> reply), pos_integer, reply}
  @type context :: %{
          optional(:thread_id) => String.t() | nil,
          optional(:turn_id) => String.t() | nil
        }

  @callback handle(method :: String.t(), params :: map, context) :: outcome

  defmodule Default do
    @moduledoc """
    Exhaustive over the app-server's server → client requests (0.154):

      * approvals, permission grants, user-input questions, MCP elicitations —
        deferred to a person with a "no" fallback
      * `item/tool/call` — run through `Longx.Codex.Tool.Runner` asynchronously
      * `account/chatgptAuthTokens/refresh`, `attestation/generate` — only exist
        on the ChatGPT-login path, which Longx never uses; refused explicitly

    Anything else is a method this version does not know: refused with
    `-32601` and logged, so a codex upgrade that adds a request is noticed.
    """
    @behaviour Longx.Codex.ServerRequest

    alias Longx.Codex.Tool.Runner

    require Logger

    @approval_timeout :timer.minutes(10)
    @tool_call_timeout :timer.minutes(5)
    @method_not_found -32601
    @not_applicable -32000

    @impl true
    def handle("item/commandExecution/requestApproval", _params, _ctx),
      do: defer(%{"decision" => "decline"})

    def handle("item/fileChange/requestApproval", _params, _ctx),
      do: defer(%{"decision" => "decline"})

    def handle("execCommandApproval", _params, _ctx), do: defer(%{"decision" => "timed_out"})
    def handle("applyPatchApproval", _params, _ctx), do: defer(%{"decision" => "timed_out"})

    def handle("item/permissions/requestApproval", _params, _ctx),
      do: defer(%{"permissions" => %{}, "scope" => "turn"})

    def handle("item/tool/requestUserInput", _params, _ctx), do: defer(%{"answers" => %{}})
    def handle("mcpServer/elicitation/request", _params, _ctx), do: defer(%{"action" => "cancel"})

    def handle("item/tool/call", params, _ctx) do
      fallback = %{
        "success" => false,
        "contentItems" => [%{"type" => "inputText", "text" => "tool call did not finish in time"}]
      }

      {:async, fn -> {:reply, Runner.run(params)} end, @tool_call_timeout, {:reply, fallback}}
    end

    def handle("account/chatgptAuthTokens/refresh", _params, _ctx),
      do:
        {:error, @not_applicable, "Longx does not use ChatGPT auth; there is no token to refresh"}

    def handle("attestation/generate", _params, _ctx),
      do:
        {:error, @not_applicable,
         "Longx does not use ChatGPT auth; attestation is not applicable"}

    def handle(method, _params, _ctx) do
      Logger.warning("codex sent an unknown server request #{method}; refusing")
      {:error, @method_not_found, "#{method} is not supported by Longx"}
    end

    defp defer(fallback), do: {:defer, @approval_timeout, {:reply, fallback}}
  end
end
