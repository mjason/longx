defmodule LongxWeb.AiRpcTest do
  @moduledoc """
  The settings page's half of the RPC surface: providers and their models,
  the search provider.
  """
  use LongxWeb.ConnCase, async: false

  alias Longx.AI

  setup do
    # seeds put DeepSeek + deepseek-flash in place; start from nothing
    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)
    :ok
  end

  defp rpc(conn, action, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/rpc/run", Jason.encode!(Map.put(params, "action", action)))
    |> json_response(200)
  end

  test "providers: create (key never read back, only its presence), update, list, delete", %{
    conn: conn
  } do
    assert %{
             "success" => true,
             "data" => %{"id" => id, "kind" => "openai_compatible", "hasApiKey" => true}
           } =
             rpc(conn, "create_provider", %{
               "fields" => ["id", "kind", "hasApiKey", "slug"],
               "input" => %{
                 "name" => "GLM",
                 "slug" => "glm",
                 "baseUrl" => "https://open.bigmodel.cn/api/paas/v4",
                 "apiKey" => "sk-secret"
               }
             })

    # an update without the key keeps it; the key itself is never a field
    assert %{"success" => true, "data" => %{"hasApiKey" => true, "requestTimeoutMs" => 30000}} =
             rpc(conn, "update_provider", %{
               "fields" => ["hasApiKey", "requestTimeoutMs"],
               "identity" => id,
               "input" => %{"requestTimeoutMs" => 30000}
             })

    # how long a stream may say nothing before it is asked again: codex's 5 min by default
    assert %{"success" => true, "data" => %{"streamIdleTimeoutMs" => 300_000}} =
             rpc(conn, "list_providers", %{"fields" => ["streamIdleTimeoutMs"]})
             |> then(&%{&1 | "data" => hd(&1["data"])})

    assert %{"success" => true, "data" => %{"streamIdleTimeoutMs" => 120_000}} =
             rpc(conn, "update_provider", %{
               "fields" => ["streamIdleTimeoutMs"],
               "identity" => id,
               "input" => %{"streamIdleTimeoutMs" => 120_000}
             })

    assert %{"success" => false} =
             rpc(conn, "list_providers", %{"fields" => ["id", "apiKey"]})

    assert %{"success" => true, "data" => [%{"id" => ^id, "name" => "GLM"}]} =
             rpc(conn, "list_providers", %{"fields" => ["id", "name", "hasApiKey", "lastError"]})

    assert %{"success" => true} = rpc(conn, "delete_provider", %{"identity" => id})
    assert %{"success" => true, "data" => []} = rpc(conn, "list_providers", %{"fields" => ["id"]})
  end

  test "models: create under a provider, edit, make default, delete — never the default; a provider goes with its models unless one is the default",
       %{conn: conn} do
    %{"success" => true, "data" => %{"id" => provider}} =
      rpc(conn, "create_provider", %{
        "fields" => ["id"],
        "input" => %{
          "name" => "DS",
          "slug" => "ds",
          "baseUrl" => "https://api.deepseek.com/v1",
          "apiKey" => "k"
        }
      })

    assert %{
             "success" => true,
             "data" => %{"id" => m1, "slug" => "deepseek-flash", "default" => false}
           } =
             rpc(conn, "create_model", %{
               "fields" => ["id", "slug", "default"],
               "input" => %{
                 "name" => "Flash",
                 "upstreamId" => "deepseek-flash",
                 "providerId" => provider,
                 "contextWindow" => 1_000_000
               }
             })

    %{"success" => true, "data" => %{"id" => m2}} =
      rpc(conn, "create_model", %{
        "fields" => ["id"],
        "input" => %{"name" => "Pro", "upstreamId" => "deepseek-pro", "providerId" => provider}
      })

    assert %{"success" => true, "data" => %{"reasoningEffort" => "high"}} =
             rpc(conn, "update_model", %{
               "fields" => ["reasoningEffort"],
               "identity" => m2,
               "input" => %{"reasoningEffort" => "high"}
             })

    assert %{"success" => true, "data" => %{"default" => true}} =
             rpc(conn, "make_default_model", %{"fields" => ["default"], "identity" => m1})

    assert %{"success" => true, "data" => models} =
             rpc(conn, "list_models", %{
               "fields" => ["id", "default", %{"provider" => ["id", "name"]}]
             })

    assert Enum.find(models, &(&1["id"] == m1))["default"]
    assert Enum.find(models, &(&1["id"] == m1))["provider"]["name"] == "DS"

    # the default model cannot go: pick another first
    assert %{"success" => false, "errors" => [%{"message" => message}]} =
             rpc(conn, "delete_model", %{"identity" => m1})

    assert message =~ "默认"
    assert %{"success" => true} = rpc(conn, "delete_model", %{"identity" => m2})

    # nor a provider while one of its models is the default
    assert %{"success" => false} = rpc(conn, "delete_provider", %{"identity" => provider})

    %{"success" => true, "data" => %{"id" => other}} =
      rpc(conn, "create_provider", %{
        "fields" => ["id"],
        "input" => %{
          "name" => "O",
          "slug" => "o",
          "baseUrl" => "https://api.openai.com/v1",
          "apiKey" => "k"
        }
      })

    %{"success" => true, "data" => %{"id" => m3}} =
      rpc(conn, "create_model", %{
        "fields" => ["id"],
        "input" => %{"name" => "G", "upstreamId" => "gpt-5", "providerId" => other}
      })

    %{"success" => true} = rpc(conn, "make_default_model", %{"identity" => m3})
    # now the first provider can go, its remaining models with it
    assert %{"success" => true} = rpc(conn, "delete_provider", %{"identity" => provider})

    assert %{"success" => true, "data" => [%{"id" => ^m3}]} =
             rpc(conn, "list_models", %{"fields" => ["id"]})
  end

  test "presets: the catalogue says what is installed; apply_preset sets a provider up in one step",
       %{
         conn: conn
       } do
    assert %{"success" => true, "data" => presets} =
             rpc(conn, "list_presets", %{
               "fields" => ["slug", "name", "kind", "installed", "providerId", "keyUrl", "models"]
             })

    assert Enum.map(presets, & &1["slug"]) == [
             "deepseek",
             "glm",
             "bailian-token-plan-personal",
             "bailian-token-plan-team",
             "openai",
             "chatgpt"
           ]

    [deepseek | _] = presets
    assert %{"installed" => false, "providerId" => nil, "kind" => "openai_compatible"} = deepseek

    assert [
             %{
               "upstreamId" => "deepseek-flash",
               "reasoningLevels" => ["none", "low", "high", "max"],
               "image" => true,
               "installed" => false
             }
             | _
           ] = deepseek["models"]

    assert %{
             "success" => true,
             "data" => %{"providerId" => provider_id, "modelIds" => [flash_id]}
           } =
             rpc(conn, "apply_preset", %{
               "fields" => ["providerId", "modelIds"],
               "input" => %{
                 "slug" => "deepseek",
                 "apiKey" => "sk-ds",
                 "models" => ["deepseek-flash"],
                 "makeDefault" => "deepseek-flash"
               }
             })

    assert %{"success" => true, "data" => [%{"id" => ^provider_id, "hasApiKey" => true}]} =
             rpc(conn, "list_providers", %{"fields" => ["id", "hasApiKey"]})

    assert %{
             "success" => true,
             "data" => [%{"id" => ^flash_id, "default" => true, "reasoningEffort" => "high"}]
           } =
             rpc(conn, "list_models", %{"fields" => ["id", "default", "reasoningEffort"]})

    # the catalogue now knows: the provider is there, one model of two
    assert %{
             "success" => true,
             "data" => [
               %{
                 "installed" => true,
                 "providerId" => ^provider_id,
                 "models" => [%{"installed" => true}, %{"installed" => false}]
               }
               | _
             ]
           } =
             rpc(conn, "list_presets", %{"fields" => ["installed", "providerId", "models"]})

    # bad choices are errors on the argument
    assert %{"success" => false, "errors" => [%{"fields" => ["models"]}]} =
             rpc(conn, "apply_preset", %{
               "fields" => ["providerId"],
               "input" => %{"slug" => "deepseek", "models" => ["gpt-9"]}
             })

    assert %{"success" => false, "errors" => [%{"fields" => ["slug"]}]} =
             rpc(conn, "apply_preset", %{
               "fields" => ["providerId"],
               "input" => %{"slug" => "nope"}
             })
  end

  test "check_model answers with ok / latency or the error, never a failure", %{conn: conn} do
    %{"success" => true, "data" => %{"id" => provider}} =
      rpc(conn, "create_provider", %{
        "fields" => ["id"],
        "input" => %{
          "name" => "Dead",
          "slug" => "dead",
          "baseUrl" => "http://127.0.0.1:1/v1",
          "apiKey" => "k"
        }
      })

    %{"success" => true, "data" => %{"id" => model}} =
      rpc(conn, "create_model", %{
        "fields" => ["id"],
        "input" => %{"name" => "X", "upstreamId" => "x", "providerId" => provider}
      })

    assert %{"success" => true, "data" => %{"ok" => false, "error" => error}} =
             rpc(conn, "check_model", %{
               "fields" => ["ok", "latencyMs", "error"],
               "input" => %{"id" => model}
             })

    assert is_binary(error)

    assert %{"success" => true, "data" => [%{"lastError" => last, "lastCheckedAt" => at}]} =
             rpc(conn, "list_providers", %{"fields" => ["lastError", "lastCheckedAt"]})

    assert is_binary(last) and is_binary(at)
  end

  test "discover_models: the provider's own list (GET /models), normalised, installed ones flagged; an error is said, not a failure",
       %{conn: conn} do
    bypass = Bypass.open()

    %{"success" => true, "data" => %{"id" => provider}} =
      rpc(conn, "create_provider", %{
        "fields" => ["id"],
        "input" => %{
          "name" => "Router",
          "slug" => "router",
          "baseUrl" => "http://localhost:#{bypass.port}/v1",
          "apiKey" => "k"
        }
      })

    Bypass.expect_once(bypass, "GET", "/v1/models", fn up ->
      up
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        ~s({"data":[{"id":"kimi-k3","owned_by":"moonshot"},{"id":"x/y","name":"X Y","context_length":32000,"reasoning":{"supported_efforts":["low","high"],"default_effort":"low"}}]})
      )
    end)

    assert %{"success" => true, "data" => %{"ok" => true, "error" => nil, "models" => [kimi, xy]}} =
             rpc(conn, "discover_models", %{
               "fields" => ["ok", "error", "models"],
               "input" => %{"id" => provider}
             })

    assert %{
             "id" => "kimi-k3",
             "name" => "kimi-k3",
             "ownedBy" => "moonshot",
             "installed" => false,
             "reasoningLevels" => []
           } = kimi

    assert %{
             "id" => "x/y",
             "name" => "X Y",
             "contextWindow" => 32000,
             "reasoningLevels" => ["low", "high"],
             "reasoningEffort" => "low"
           } = xy

    Bypass.down(bypass)

    assert %{"success" => true, "data" => %{"ok" => false, "error" => error, "models" => []}} =
             rpc(conn, "discover_models", %{
               "fields" => ["ok", "error", "models"],
               "input" => %{"id" => provider}
             })

    assert error =~ "unreachable"
  end

  test "the search provider: listed with its key's presence, editable", %{conn: conn} do
    assert %{"success" => true, "data" => [%{"slug" => "tavily", "id" => id} | _]} =
             rpc(conn, "list_search_providers", %{
               "fields" => ["id", "slug", "name", "hasApiKey", "default"]
             })

    assert %{"success" => true, "data" => %{"hasApiKey" => true}} =
             rpc(conn, "update_search_provider", %{
               "fields" => ["hasApiKey"],
               "identity" => id,
               "input" => %{"apiKey" => "tvly-x"}
             })
  end
end
