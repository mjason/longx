defmodule LongxWeb.AI.SearchController do
  @moduledoc """
  `POST /ai/v1/alpha/search` — codex's standalone web search endpoint
  (`codex-api/src/endpoint/search.rs` posts here with the provider's bearer,
  i.e. our gateway token). Executes the `web.run` commands via
  `Longx.AI.Search` and answers `{output, results}`.

  Configuration problems are reported *in the output* with status 200: codex
  turns a non-2xx into a fatal tool error, whereas a readable message lets the
  model carry on without search.
  """

  use LongxWeb, :controller

  alias Longx.AI
  alias Longx.AI.{Gateway, Search}

  def create(conn, _params) do
    case conn.body_params do
      %{"commands" => commands} = request when is_map(commands) ->
        json(conn, search(request))

      _ ->
        Gateway.error(conn, 400, "body is not a codex search request (missing commands)")
    end
  end

  # no search provider (or one without a key) → `open` still works (we fetch
  # pages ourselves), `search_query` is answered with "no search provider"
  defp search(request) do
    target =
      case AI.resolve_search_target() do
        {:ok, target} -> target
        {:error, _} -> nil
      end

    {:ok, result} = Search.run(request, target)
    result
  end
end
