defmodule LongxWeb.PageController do
  @moduledoc """
  Serves the React SPA shell. The client router owns every path, so any
  HTML navigation — `/`, a deep link, a refresh on `/p/x/t/y` — gets the
  same shell. Requests that cannot be a page (an `Accept` without HTML, a
  path that looks like a file) get a plain 404 instead: a missing asset
  must never come back as HTML.
  """

  use LongxWeb, :controller

  def spa(conn, params) do
    path = Map.get(params, "path", [])

    if page_request?(conn, path) do
      conn |> put_format("html") |> render(:index)
    else
      send_resp(conn, 404, "Not Found")
    end
  end

  defp page_request?(conn, path), do: accepts_html?(conn) and not file_like?(path)

  # no Accept header (curl, tests) counts as a browser navigation
  defp accepts_html?(conn) do
    case get_req_header(conn, "accept") do
      [] -> true
      [accept | _] -> accept =~ "text/html" or accept =~ "*/*"
    end
  end

  defp file_like?([]), do: false
  defp file_like?(path), do: path |> List.last() |> Path.extname() != ""
end
