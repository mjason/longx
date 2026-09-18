defmodule Longx.Credentials.PlugTest do
  @moduledoc """
  The agent's side of credentials: it sees names and statuses, makes
  requests through the service layer, and never a secret — not in a tool
  result, not in an error.
  """
  use Longx.DataCase, async: false

  alias Longx.Agent.{Context, Step}
  alias Longx.Agent.Plugs.Credentials, as: CredPlug
  alias Longx.Credentials
  alias Longx.Credentials.Credential

  setup do
    Ash.bulk_destroy!(Credential, :destroy, %{}, authorize?: false)
    bypass = Bypass.open()
    %{bypass: bypass, base: "http://localhost:#{bypass.port}", ctx: %Context{cwd: "/tmp"}}
  end

  defp tool!(name),
    do: Enum.find(CredPlug.__agent_tools__(), &(&1.name == name)) || flunk("no tool #{name}")

  test "the plug mounts four tools in the longx namespace and says how to use them" do
    step = CredPlug.call(%Step{phase: :request}, CredPlug.init([]))
    names = step.tools |> Map.values() |> Enum.map(& &1.name) |> Enum.sort()

    assert names ==
             ~w(credential_create credential_login credential_rotate credentials_list http_request)

    assert Enum.all?(Map.values(step.tools), &(&1.namespace == "longx"))
    text = Enum.join(step.instructions, "\n")
    assert text =~ "http_request"
    assert text =~ "never"
    # http_request is for requests that need a credential, not for HTTP in general:
    # a plain page or API goes through curl / web_fetch (no clipping, redirects followed)
    assert text =~ "only"
    assert text =~ "curl"
    assert text =~ "web_fetch"
    assert tool!("http_request").description =~ "Only"
    assert tool!("http_request").timeout >= 60_000
    assert tool!("credential_login").timeout >= 600_000
  end

  test "credentials_list names each with kind, status, hosts and expiry — no value", %{ctx: ctx} do
    assert {:ok, "no credentials" <> _} = CredPlug.credentials_list(%{}, ctx)

    {:ok, _} =
      Credentials.create_api_key(%{
        name: "svc",
        label: "Service",
        allowed_hosts: ["api.example"],
        secret: "sk-hidden"
      })

    {:ok, _} =
      Credentials.create_oauth2(%{
        name: "oa",
        allowed_hosts: ["mcp.example"],
        authorize_url: "https://mcp.example/authorize",
        token_url: "https://mcp.example/token",
        client_id: "cid"
      })

    assert {:ok, text} = CredPlug.credentials_list(%{}, ctx)
    assert text =~ "svc"
    assert text =~ "api_key"
    assert text =~ "ready"
    assert text =~ "api.example"
    assert text =~ "oa"
    assert text =~ "needs_login"
    refute text =~ "sk-hidden"
  end

  test "http_request goes through the service layer: injected, scrubbed, refused off-host",
       %{ctx: ctx, bypass: bypass, base: base} do
    {:ok, _} =
      Credentials.create_api_key(%{
        name: "svc",
        allowed_hosts: ["localhost"],
        secret: "sk-hidden"
      })

    Bypass.expect_once(bypass, "POST", "/rpc", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk-hidden"]
      assert body == ~s({"jsonrpc":"2.0","method":"tools/list","id":1})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result":{"echo":"sk-hidden"}}))
    end)

    assert {:ok, text} =
             CredPlug.http_request(
               %{
                 "credential" => "svc",
                 "method" => "POST",
                 "url" => base <> "/rpc",
                 "headers" => %{"content-type" => "application/json"},
                 "body" => ~s({"jsonrpc":"2.0","method":"tools/list","id":1})
               },
               ctx
             )

    assert text =~ "HTTP 200"
    assert text =~ ~s("echo":"[redacted:svc]")
    refute text =~ "sk-hidden"

    assert {:error, message} =
             CredPlug.http_request(
               %{"credential" => "svc", "url" => "https://evil.example/x"},
               ctx
             )

    assert message =~ "evil.example"
    assert message =~ "allowed"

    assert {:error, message} =
             CredPlug.http_request(%{"credential" => "nope", "url" => base}, ctx)

    assert message =~ "no credential"
  end

  test "a long body is clipped head and tail like a command's output",
       %{ctx: ctx, bypass: bypass, base: base} do
    {:ok, _} =
      Credentials.create_api_key(%{
        name: "svc",
        allowed_hosts: ["localhost"],
        secret: "sk-hidden"
      })

    big = String.duplicate("x", 100_000) <> "END"
    Bypass.expect_once(bypass, "GET", "/big", fn conn -> Plug.Conn.send_resp(conn, 200, big) end)

    assert {:ok, text} =
             CredPlug.http_request(%{"credential" => "svc", "url" => base <> "/big"}, ctx)

    assert byte_size(text) < 50_000
    assert text =~ "truncated"
    assert String.ends_with?(String.trim(text), "END")
  end

  test "credential_login and credential_create need the person: outside an agent they say so",
       %{ctx: ctx} do
    {:ok, _} =
      Credentials.create_oauth2(%{
        name: "oa",
        allowed_hosts: ["mcp.example"],
        authorize_url: "https://mcp.example/authorize",
        token_url: "https://mcp.example/token",
        client_id: "cid"
      })

    assert {:error, message} = CredPlug.credential_login(%{"credential" => "oa"}, ctx)
    assert message =~ "agent"

    assert {:error, message} =
             CredPlug.credential_create(
               %{"name" => "k", "kind" => "api_key", "allowed_hosts" => ["a.example"]},
               ctx
             )

    assert message =~ "agent"
    # nothing was created without the secret
    assert Credentials.list() |> Enum.map(& &1.name) == ["oa"]

    assert {:error, message} = CredPlug.credential_login(%{"credential" => "nope"}, ctx)
    assert message =~ "no credential"
  end

  describe "secret_from: the agent copies a key that is already on the machine, never seeing it" do
    setup do
      dir = Path.join(System.tmp_dir!(), "longx-cred-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      var = "LONGX_TEST_KEY_#{System.unique_integer([:positive])}"
      System.put_env(var, "sk-from-env")
      on_exit(fn -> System.delete_env(var) end)
      %{dir: dir, var: var}
    end

    test "an environment variable", %{ctx: ctx, var: var} do
      assert {:ok, text} =
               CredPlug.credential_create(
                 %{
                   "name" => "e",
                   "kind" => "api_key",
                   "allowed_hosts" => ["a.example"],
                   "secret_from" => "env:#{var}"
                 },
                 ctx
               )

      refute text =~ "sk-from-env"
      assert {:ok, %{secret: "sk-from-env"}} = Credentials.reveal("e")
    end

    test "a whole file, a KEY=value line (export, quotes), a JSON key", %{ctx: ctx, dir: dir} do
      File.write!(Path.join(dir, "token.txt"), "sk-whole-file\n")

      File.write!(
        Path.join(dir, ".env"),
        "# keys\nexport OTHER=1\nexport API_KEY=\"sk-dotenv\"\n"
      )

      File.write!(Path.join(dir, "config.json"), ~s({"token": "sk-json", "n": 1}))
      File.write!(Path.join(dir, "config.yml"), "token: sk-yaml\n")

      for {name, from, value} <- [
            {"f1", "file:#{dir}/token.txt", "sk-whole-file"},
            {"f2", "file:#{dir}/.env#API_KEY", "sk-dotenv"},
            {"f3", "file:#{dir}/config.json#token", "sk-json"},
            {"f4", "file:#{dir}/config.yml#token", "sk-yaml"}
          ] do
        assert {:ok, text} =
                 CredPlug.credential_create(
                   %{
                     "name" => name,
                     "kind" => "api_key",
                     "allowed_hosts" => ["a.example"],
                     "secret_from" => from
                   },
                   ctx
                 )

        refute text =~ value
        assert {:ok, %{secret: ^value}} = Credentials.reveal(name)
      end
    end

    test "a source that has nothing is an error, nothing is created; an oauth2 client secret comes the same way",
         %{ctx: ctx, dir: dir, var: var} do
      assert {:error, message} =
               CredPlug.credential_create(
                 %{
                   "name" => "x",
                   "kind" => "api_key",
                   "allowed_hosts" => ["a.example"],
                   "secret_from" => "env:LONGX_NO_SUCH_VAR"
                 },
                 ctx
               )

      assert message =~ "LONGX_NO_SUCH_VAR"
      File.write!(Path.join(dir, ".env"), "A=1\n")

      assert {:error, message} =
               CredPlug.credential_create(
                 %{
                   "name" => "x",
                   "kind" => "api_key",
                   "allowed_hosts" => ["a.example"],
                   "secret_from" => "file:#{dir}/.env#B"
                 },
                 ctx
               )

      assert message =~ "B"
      assert Credentials.list() == []

      assert {:ok, _} =
               CredPlug.credential_create(
                 %{
                   "name" => "oa",
                   "kind" => "oauth2",
                   "allowed_hosts" => ["mcp.example"],
                   "authorize_url" => "https://mcp.example/authorize",
                   "token_url" => "https://mcp.example/token",
                   "client_id" => "cid",
                   "secret_from" => "env:#{var}"
                 },
                 ctx
               )

      assert {:ok, %{client_secret: "sk-from-env"}} = Credentials.reveal("oa")
    end

    test "credential_rotate replaces an API key from the machine", %{ctx: ctx, var: var} do
      {:ok, _} =
        Credentials.create_api_key(%{name: "svc", allowed_hosts: ["a.example"], secret: "sk-old"})

      assert {:ok, text} =
               CredPlug.credential_rotate(
                 %{"credential" => "svc", "secret_from" => "env:#{var}"},
                 ctx
               )

      refute text =~ "sk-from-env"
      assert {:ok, %{secret: "sk-from-env"}} = Credentials.reveal("svc")

      assert {:error, msg} =
               CredPlug.credential_rotate(
                 %{"credential" => "nope", "secret_from" => "env:#{var}"},
                 ctx
               )

      assert msg =~ "no credential"
    end
  end
end
