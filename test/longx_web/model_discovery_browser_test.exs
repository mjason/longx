defmodule LongxWeb.ModelDiscoveryBrowserTest do
  @moduledoc "Real Chromium → Phoenix/GraphQL → Ash/SQLite → a local Codex fixture. No production data."
  use Longx.DataCase, async: false
  alias Longx.AI
  @moduletag :integration
  @moduletag timeout: 120_000

  test "cross-provider discovery import and model health checks in the real settings page" do
    # Unit tests deliberately use a static manifest fixture. This integration
    # needs the actual bundle built immediately before running it.
    vite = Application.get_env(:longx, LongxWeb.Vite)
    cache_key = {LongxWeb.Vite, :manifest}
    cached = :persistent_term.get(cache_key, :not_cached)

    Application.put_env(:longx, LongxWeb.Vite,
      manifest: {:priv, "static/assets/.vite/manifest.json"},
      entries: ["js/index.tsx"],
      dev_server: nil
    )

    :persistent_term.erase(cache_key)

    on_exit(fn ->
      Application.put_env(:longx, LongxWeb.Vite, vite)
      :persistent_term.erase(cache_key)
      if cached != :not_cached, do: :persistent_term.put(cache_key, cached)
    end)

    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)
    bypass = Bypass.open()
    ids = ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra"]

    ls =
      AI.create_provider!(%{
        name: "LS fixture",
        slug: "ls-fixture",
        base_url: "http://localhost:#{bypass.port}/unused"
      })

    for id <- ids,
        do: AI.create_model!(%{provider_id: ls.id, upstream_id: id, slug: id, name: id})

    cred =
      Longx.Credentials.create_oauth2!(%{
        name: "model-browser-fixture",
        allowed_hosts: ["localhost"]
      })

    claims =
      Jason.encode!(%{
        "https://api.openai.com/auth" => %{"chatgpt_account_id" => "browser-fixture"}
      })

    token = "fixture." <> Base.url_encode64(claims, padding: false) <> ".fixture"

    Longx.Credentials.store_tokens!(cred, %{
      access_token: token,
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    })

    chatgpt =
      AI.create_provider!(%{
        name: "ChatGPT fixture",
        slug: "chatgpt",
        kind: :openai,
        base_url: "http://localhost:#{bypass.port}/backend-api/codex",
        credential_id: cred.id
      })

    existing =
      for id <- ["gpt-6.1-sol", "gpt-6-luna", "gpt-6-sol"],
          do:
            AI.create_model!(%{
              provider_id: chatgpt.id,
              upstream_id: id,
              slug: id,
              name: id,
              context_window: 500_000
            })

    Bypass.stub(bypass, "GET", "/backend-api/codex/models", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          models:
            Enum.map(
              ids,
              &%{slug: &1, display_name: &1, visibility: "list", context_window: 272_000}
            )
        })
      )
    end)

    Bypass.stub(bypass, "POST", "/backend-api/codex/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      assert is_list(body["input"])
      assert body["stream"] == true
      assert is_binary(body["instructions"])
      refute Map.has_key?(body, "max_output_tokens")
      assert {"originator", "codex_cli_rs"} in conn.req_headers
      assert {"chatgpt-account-id", "browser-fixture"} in conn.req_headers
      failed? = body["model"] == "gpt-5.6-terra"
      type = if failed?, do: "response.failed", else: "response.completed"

      response =
        if failed?,
          do: %{status: "failed", error: %{message: "fixture model not allowed"}},
          else: %{status: "completed"}

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(
        200,
        "event: #{type}\ndata: #{Jason.encode!(%{type: type, response: response})}\n\n"
      )
    end)

    server = start_supervised!({Bandit, plug: LongxWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {out, code} =
      System.cmd(
        "node",
        [
          "assets/scripts/test-model-discovery-live.mjs",
          "http://localhost:#{port}",
          ls.id,
          chatgpt.id
        ],
        stderr_to_stdout: true
      )

    assert code == 0, out
    assert out =~ "real model discovery and health checks passed"
    assert Enum.count(AI.list_models!(), &(&1.provider_id == ls.id)) == 3
    assert Enum.count(AI.list_models!(), &(&1.provider_id == chatgpt.id)) == 6

    for old <- existing do
      preserved = AI.get_model_by_slug!(old.slug)
      assert preserved.id == old.id
      assert preserved.context_window == 500_000
    end
  end
end
