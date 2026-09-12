defmodule Longx.Codex.ServerRequest do
  @moduledoc """
  How `Longx.Codex.Connection` answers requests the app-server sends *to us*
  (approvals, user-input questions, MCP elicitations, auth refresh…).

  A handler returns one of:

    * `{:reply, result}` — answer now
    * `{:error, code, message}` — refuse now
    * `{:defer, timeout_ms, fallback}` — the answer comes later through
      `Longx.Codex.Connection.respond/2` (typically from the UI); if nobody
      answers within `timeout_ms` the connection sends `fallback`
      (`{:reply, result}` or `{:error, code, message}`) so the turn never
      hangs forever

  Configure with `config :longx, Longx.Codex.Connection, server_request_handler: Mod`;
  the default is `Longx.Codex.ServerRequest.Default`.
  """

  @type reply :: {:reply, map} | {:error, integer, String.t()}
  @type outcome :: reply | {:defer, pos_integer, reply}
  @type context :: %{
          optional(:thread_id) => String.t() | nil,
          optional(:turn_id) => String.t() | nil
        }

  @callback handle(method :: String.t(), params :: map, context) :: outcome

  defmodule Default do
    @moduledoc """
    Defers everything a person should decide on (with a "no" fallback) and
    refuses what we do not support. No ChatGPT auth is ever involved.
    """
    @behaviour Longx.Codex.ServerRequest

    @approval_timeout :timer.minutes(10)
    @method_not_found -32601

    @impl true
    def handle("item/commandExecution/requestApproval", _params, _ctx),
      do: defer(%{"decision" => "decline"})

    def handle("item/fileChange/requestApproval", _params, _ctx),
      do: defer(%{"decision" => "decline"})

    def handle("execCommandApproval", _params, _ctx), do: defer(%{"decision" => "timed_out"})
    def handle("applyPatchApproval", _params, _ctx), do: defer(%{"decision" => "timed_out"})

    def handle("item/permissions/requestApproval", _params, _ctx),
      do: defer(%{"permissions" => %{}})

    def handle("item/tool/requestUserInput", _params, _ctx), do: defer(%{"answers" => %{}})
    def handle("mcpServer/elicitation/request", _params, _ctx), do: defer(%{"action" => "cancel"})

    def handle(method, _params, _ctx),
      do: {:error, @method_not_found, "#{method} is not supported by Longx"}

    defp defer(fallback), do: {:defer, @approval_timeout, {:reply, fallback}}
  end
end
