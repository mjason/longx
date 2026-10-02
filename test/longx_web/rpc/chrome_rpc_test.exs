defmodule LongxWeb.ChromeRpcTest do
  @moduledoc "The person's browsers on the wire: the directory, approvals, names, limits, aliases, the extension."
  use LongxWeb.ConnCase, async: false

  alias Longx.Chrome
  alias Longx.Chrome.Aliases

  setup do
    for b <- Chrome.list_browsers!(), do: :ok = Chrome.destroy_browser(b)
    for %{name: name} <- Aliases.all(), do: Aliases.delete(name)
    :ok
  end

  test "a pending browser is listed, approved, renamed, limited, and revoked", %{
    conn: conn
  } do
    {:ok, b} =
      Chrome.connect("rpc-1", nil, %{
        "name" => "Test Chrome",
        "platform" => "linux",
        "peer_ip" => "192.168.1.42"
      })

    assert %{"success" => true, "data" => %{"browsers" => [row]}} =
             rpc(conn, "list_chrome_browsers", %{"fields" => ["browsers"]})

    assert %{
             "id" => id,
             "name" => "Test Chrome",
             "status" => "pending",
             "connected" => false,
             "maxTabs" => 6,
             "device" => %{"peer_ip" => "192.168.1.42"},
             "tabs" => []
           } = row

    assert id == b.id

    assert %{"success" => true, "data" => %{"ok" => true}} =
             rpc(conn, "approve_chrome_browser", %{"fields" => ["ok"], "input" => %{"id" => id}})

    assert %{"success" => true} =
             rpc(conn, "rename_chrome_browser", %{
               "fields" => ["ok"],
               "input" => %{"id" => id, "name" => "qa 机"}
             })

    assert %{"success" => true} =
             rpc(conn, "set_chrome_browser_max_tabs", %{
               "fields" => ["ok"],
               "input" => %{"id" => id, "maxTabs" => 3}
             })

    assert %{
             "data" => %{
               "browsers" => [
                 %{
                   "name" => "qa 机",
                   "status" => "approved",
                   "maxTabs" => 3
                 }
               ]
             }
           } =
             rpc(conn, "list_chrome_browsers", %{"fields" => ["browsers"]})

    assert %{"success" => true} =
             rpc(conn, "revoke_chrome_browser", %{"fields" => ["ok"], "input" => %{"id" => id}})

    assert %{"data" => %{"browsers" => [%{"status" => "revoked"}]}} =
             rpc(conn, "list_chrome_browsers", %{"fields" => ["browsers"]})

    assert %{"success" => false, "errors" => [%{"fields" => ["id"]}]} =
             rpc(conn, "approve_chrome_browser", %{
               "fields" => ["ok"],
               "input" => %{"id" => Ash.UUID.generate()}
             })
  end

  test "rejecting a request removes it", %{conn: conn} do
    {:ok, b} = Chrome.connect("rpc-2", nil, %{"name" => "Test Chrome"})

    assert %{"success" => true} =
             rpc(conn, "reject_chrome_browser", %{"fields" => ["ok"], "input" => %{"id" => b.id}})

    assert %{"data" => %{"browsers" => []}} =
             rpc(conn, "list_chrome_browsers", %{"fields" => ["browsers"]})
  end

  test "aliases: set, default, delete; a bad one is an error on its field", %{conn: conn} do
    {:ok, a} = Chrome.connect("rpc-a", nil, %{"name" => "A"})
    fields = ["aliases", "default"]

    assert %{"success" => true, "data" => %{"aliases" => [], "default" => nil}} =
             rpc(conn, "chrome_aliases", %{"fields" => fields})

    assert %{
             "success" => true,
             "data" => %{"aliases" => [%{"name" => "qa-chrome", "browsers" => [_]}]}
           } =
             rpc(conn, "set_chrome_alias", %{
               "fields" => fields,
               "input" => %{"name" => "qa-chrome", "browsers" => [a.id]}
             })

    assert %{"success" => false, "errors" => [%{"fields" => ["browsers"]}]} =
             rpc(conn, "set_chrome_alias", %{
               "fields" => fields,
               "input" => %{"name" => "empty", "browsers" => []}
             })

    assert %{"success" => true, "data" => %{"default" => "qa-chrome"}} =
             rpc(conn, "set_chrome_default_alias", %{
               "fields" => fields,
               "input" => %{"name" => "qa-chrome"}
             })

    assert %{"success" => true, "data" => %{"default" => nil}} =
             rpc(conn, "set_chrome_default_alias", %{
               "fields" => fields,
               "input" => %{"name" => nil}
             })

    assert %{"success" => true, "data" => %{"aliases" => []}} =
             rpc(conn, "delete_chrome_alias", %{
               "fields" => fields,
               "input" => %{"name" => "qa-chrome"}
             })
  end

  test "the extension's address and version", %{conn: conn} do
    assert %{
             "success" => true,
             "data" => %{
               "url" => "/extension/longx-chrome.zip",
               "minimumChrome" => "118",
               "built" => built
             }
           } =
             rpc(conn, "chrome_extension", %{
               "fields" => ["url", "version", "built", "minimumChrome"]
             })

    assert is_boolean(built)
  end

  test "the project's definition says what `plug Browser` resolves to", %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "longx-rpc-def-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".longx/local"))
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(
      Path.join(root, ".longx/local/agent.exs"),
      "import Longx.Agent.Config\nagent do\n  version 1\n  extends :default\n  plug Browser, browser: \"qa\"\nend\n"
    )

    {:ok, project} =
      Longx.Projects.create_project(%{name: "rpc def #{Path.basename(root)}", root_path: root})

    assert %{"success" => true, "data" => %{"present" => true, "browser" => browser}} =
             rpc(conn, "agent_definition", %{
               "fields" => ["present", %{"browser" => ["alias", "maxTabs", "state", "browser"]}],
               "input" => %{"id" => project.id}
             })

    assert browser == %{
             "alias" => "qa",
             "maxTabs" => 1,
             "state" => "unknown_alias",
             "browser" => nil
           }
  end
end
