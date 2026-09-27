defmodule LongxWeb.ExtensionController do
  @moduledoc """
  `GET /extension/longx-chrome.zip` — the Longx Chrome extension as a zip
  the person loads unpacked (`chrome://extensions` → 开发者模式 → 加载已解压).
  The build (`npm run build:extension`, part of `mix assets.build`) leaves
  the extension under `priv/static/extension/unpacked/`; the zip is made
  from it on request (Erlang's `:zip`, in memory) so a release carries the
  files, not an archive to keep in step with them. A 404 says how to build
  it when it is missing (a development checkout before `mix assets.build`).
  """

  use LongxWeb, :controller

  alias Longx.Chrome

  def download(conn, _params) do
    case Chrome.extension_zip() do
      {:ok, bytes, version} ->
        conn
        |> put_resp_content_type("application/zip")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="longx-chrome-#{version}.zip")
        )
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, bytes)

      {:error, :not_built} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(
          404,
          "the extension is not built on this Longx: run `mix assets.build` (npm run build:extension)"
        )
    end
  end
end
