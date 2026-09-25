defmodule LongxWeb.ApiController do
  @moduledoc """
  A conversation as JSON for another agent to look into: the page's address
  with `/api` in front (`/api/p/<slug>/t/<id>` — `?turns=N|all`, `?full=1`;
  `/api/p/<slug>` lists the project's conversations). Always JSON, whatever
  the client accepts (an agent's fetch tool asks for HTML). No auth — the
  single-user boundary of the RPC. The work is `Longx.Projects.Report`'s.
  """

  use LongxWeb, :controller

  alias Longx.Projects.Report

  def project(conn, %{"slug" => slug}),
    do: respond(conn, Report.project(slug, base: base(conn)))

  def thread(conn, %{"slug" => slug, "id" => id} = params) do
    respond(
      conn,
      Report.thread(slug, id,
        base: base(conn),
        turns: turns(params["turns"]),
        full: params["full"] in ["1", "true"]
      )
    )
  end

  defp respond(conn, {:ok, body}), do: json(conn, LongxWeb.Wire.clean(body, "api"))

  defp respond(conn, {:error, :not_found}),
    do: conn |> put_status(:not_found) |> json(%{"error" => "not found"})

  defp turns("all"), do: :all

  defp turns(n) when is_binary(n) do
    case Integer.parse(n) do
      {k, ""} when k > 0 -> k
      _ -> 20
    end
  end

  defp turns(_), do: 20

  # the address the client reached, for the links in the answer
  defp base(conn), do: "#{conn.scheme}://#{conn.host}:#{conn.port}"
end
