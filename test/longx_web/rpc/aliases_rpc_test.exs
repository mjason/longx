defmodule LongxWeb.AliasesRpcTest do
  @moduledoc "Model tiers and aliases on the wire."
  use LongxWeb.ConnCase, async: false

  alias Longx.AI

  setup do
    Ash.bulk_destroy!(Longx.System.Setting, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)
    n = System.unique_integer([:positive])

    provider =
      AI.create_provider!(%{
        name: "Up #{n}",
        slug: "up-#{n}",
        base_url: "http://localhost:1/v1",
        api_key: "k"
      })

    a =
      AI.create_model!(%{name: "A", upstream_id: "a", slug: "model-a", provider_id: provider.id})

    _b =
      AI.create_model!(%{name: "B", upstream_id: "b", slug: "model-b", provider_id: provider.id})

    AI.make_default_model!(a)
    :ok
  end

  defp rpc(conn, action, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/rpc/run", Jason.encode!(Map.put(params, "action", action)))
    |> json_response(200)
  end

  @fields ["name", "label", "models", "builtin"]

  test "list, map a tier, add and remove an alias; a bad name is an error on its field", %{
    conn: conn
  } do
    assert %{
             "success" => true,
             "data" => [
               %{"name" => "ultra", "label" => "旗舰", "models" => [], "builtin" => true} | _
             ]
           } =
             rpc(conn, "model_aliases", %{"fields" => @fields})

    assert %{
             "success" => true,
             "data" => %{"name" => "ultra", "models" => ["model-b", "model-a"]}
           } =
             rpc(conn, "set_model_alias", %{
               "fields" => @fields,
               "input" => %{"name" => "ultra", "models" => ["model-b", "model-a"]}
             })

    assert %{"success" => true, "data" => %{"name" => "青龙", "builtin" => false}} =
             rpc(conn, "set_model_alias", %{
               "fields" => @fields,
               "input" => %{"name" => "青龙", "models" => ["model-a"]}
             })

    assert %{"success" => false, "errors" => [%{"fields" => ["name"]}]} =
             rpc(conn, "set_model_alias", %{
               "fields" => @fields,
               "input" => %{"name" => "model-a", "models" => ["model-b"]}
             })

    assert %{"success" => true} = rpc(conn, "delete_model_alias", %{"input" => %{"name" => "青龙"}})

    assert %{"success" => false} =
             rpc(conn, "delete_model_alias", %{"input" => %{"name" => "ultra"}})

    assert {:ok, ["model-b", "model-a"]} = AI.Aliases.resolve("ultra")
  end
end
