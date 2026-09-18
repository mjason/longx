defmodule LongxWeb.CallbackController do
  @moduledoc """
  `GET /callback/:id` — where a third party sends the browser back after
  a login a tool asked the person for (`Longx.Agent.Context.ask/2` with
  `callback: true`): the query goes to the waiting tool, the page tells
  the person to return to Longx. A stale id is a 404 page.
  """

  use LongxWeb, :controller

  def show(conn, %{"id" => id} = params) do
    query = Map.delete(params, "id")

    case Longx.Agent.Kernel.Asks.deliver(id, query) do
      :ok -> page(conn, 200, "完成了", "可以回到 Longx 了，这个页面可以关掉。")
      {:error, :unknown} -> page(conn, 404, "这个链接已失效", "没有工具在等它了——回到 Longx 重新发起一次。")
    end
  end

  @doc """
  `GET /callback/credentials?code=…&state=…` — the stable redirect URI of
  every OAuth2 credential (`Longx.Credentials.OAuth`): the state finds
  the login, the code is exchanged and the tokens stored; an unknown
  state is a 404 page, a refused exchange says why.
  """
  def credentials(conn, %{"state" => state} = params) do
    case Longx.Credentials.OAuth.complete(state, Map.delete(params, "state")) do
      {:ok, cred} ->
        page(conn, 200, "登录成功", "凭证「#{cred.name}」已保存，可以回到 Longx 了，这个页面可以关掉。")

      {:error, :unknown_state} ->
        page(conn, 404, "这个链接已失效", "没有登录在等它了——回到 Longx 重新发起一次。")

      {:error, message} ->
        page(
          conn,
          400,
          "登录没有完成",
          Plug.HTML.html_escape_to_iodata(message) |> IO.iodata_to_binary()
        )
    end
  end

  def credentials(conn, _params),
    do: page(conn, 400, "登录没有完成", "回调里没有 state 参数。")

  defp page(conn, status, title, text) do
    html = """
    <!doctype html><html lang="zh"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>#{title} · Longx</title>
    <style>body{font-family:system-ui,sans-serif;display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0;background:#1c1e24;color:#e6e6e6}
    main{max-width:28rem;padding:2rem;text-align:center}h1{font-size:1.4rem;margin:0 0 .75rem}p{color:#9aa0aa;margin:0}</style></head>
    <body><main><h1>#{title}</h1><p>#{text}</p></main></body></html>
    """

    conn |> put_resp_content_type("text/html") |> send_resp(status, html)
  end
end
