defmodule Longx.ChromeTest do
  use Longx.DataCase, async: false

  alias Longx.Chrome
  alias Longx.Chrome.{Aliases, Browser, Connection}

  @device %{"name" => "MJ 的 MacBook · Chrome 153", "platform" => "mac", "extension" => "0.1.0"}

  setup do
    for b <- Chrome.list_browsers!(), do: :ok = Chrome.destroy_browser(b)
    for %{name: name} <- Aliases.all(), do: Aliases.delete(name)
    :ok
  end

  describe "pairing" do
    test "deleting an approved device invalidates its token and cleans aliases and defaults" do
      {:ok, a} = Chrome.connect("delete-a", nil, @device)
      {:ok, b} = Chrome.connect("delete-b", nil, @device)
      {:ok, _, token} = Chrome.approve(a.id)
      :ok = Aliases.put("only-a", [a.id])
      :ok = Aliases.put("shared", [a.id, b.id])
      :ok = Aliases.set_default("only-a")

      assert :ok = Chrome.delete(a.id)
      assert {:error, _} = Chrome.get_browser(a.id)
      assert {:error, :bad_token} = Chrome.connect("delete-a", token, @device)
      assert [%{name: "shared", browsers: [id]}] = Aliases.all()
      assert id == b.id
      assert Aliases.default() == nil
      assert {:ok, %{status: :pending}} = Chrome.connect("delete-a", nil, @device)
    end

    test "deleting a revoked device removes it without affecting other records" do
      {:ok, a} = Chrome.connect("delete-revoked", nil, @device)
      {:ok, _} = Chrome.revoke(a.id)
      assert :ok = Chrome.delete(a.id)
      assert [] = Chrome.list_browsers!()
      assert {:error, _} = Chrome.delete(a.id)
    end

    test "an extension without a token is a pending row named after its device; the same install is the same row" do
      assert {:ok, %Browser{status: :pending, name: "MJ 的 MacBook · Chrome 153"} = b} =
               Chrome.connect("install-1", nil, @device)

      assert {:ok, %Browser{id: id}} = Chrome.connect("install-1", nil, @device)
      assert id == b.id
      assert [_one] = Chrome.list_browsers!()
    end

    test "approving gives a token the extension connects with; a wrong or missing token asks again" do
      {:ok, b} = Chrome.connect("install-2", nil, @device)
      assert {:ok, %Browser{status: :approved}, token} = Chrome.approve(b.id)
      assert is_binary(token) and byte_size(token) > 20

      assert {:ok, %Browser{status: :approved, id: id}} =
               Chrome.connect("install-2", token, @device)

      assert id == b.id
      # a token of another install is nobody's
      assert {:error, :bad_token} = Chrome.connect("install-other", token, @device)
      assert {:error, :bad_token} = Chrome.connect("install-2", "made-up", @device)
      # approved but silent about its token: it must ask again, not become pending by itself
      assert {:error, :bad_token} = Chrome.connect("install-2", nil, @device)
    end

    test "revoking voids the token; the extension asking again is pending again; rejecting removes the row" do
      {:ok, b} = Chrome.connect("install-3", nil, @device)
      {:ok, _, token} = Chrome.approve(b.id)
      assert {:ok, %Browser{status: :revoked}} = Chrome.revoke(b.id)
      assert {:error, :bad_token} = Chrome.connect("install-3", token, @device)
      assert {:ok, %Browser{status: :pending}} = Chrome.connect("install-3", nil, @device)

      assert :ok = Chrome.reject(b.id)
      assert [] = Chrome.list_browsers!()
    end

    test "the person's own name stays when the device reconnects" do
      {:ok, b} = Chrome.connect("install-4", nil, @device)
      {:ok, _} = Chrome.rename(b.id, "qa 机")
      {:ok, _, token} = Chrome.approve(b.id)

      assert {:ok, %Browser{name: "qa 机"}} =
               Chrome.connect("install-4", token, %{"name" => "Renamed device"})
    end

    test "max tabs are kept on the row" do
      {:ok, b} = Chrome.connect("install-5", nil, @device)
      assert {:ok, %Browser{max_tabs: 2}} = Chrome.set_max_tabs(b.id, 2)
    end

    test "an explicit extension rename follows its revision, not an ordinary reconnect" do
      device = Map.put(@device, "name_revision", 0)
      {:ok, b} = Chrome.connect("named-extension", nil, device)
      {:ok, _, token} = Chrome.approve(b.id)
      {:ok, _} = Chrome.rename(b.id, "Server-side name")

      assert {:ok, %Browser{name: "Server-side name"}} =
               Chrome.connect("named-extension", token, device)

      renamed = Map.merge(device, %{"name" => "桌面 Mac", "name_revision" => 1})

      assert {:ok, %Browser{id: id, name: "桌面 Mac"}} =
               Chrome.connect("named-extension", token, renamed)

      assert id == b.id
      {:ok, _} = Chrome.rename(id, "New server-side name")

      assert {:ok, %Browser{name: "New server-side name"}} =
               Chrome.connect("named-extension", token, renamed)
    end

    test "the directory says whether a browser is connected" do
      {:ok, b} = Chrome.connect("install-6", nil, @device)
      assert [%{connected: false, status: "pending", tabs: []}] = Chrome.directory()
      :ok = Connection.register(b.id, :approved)
      assert [%{connected: true}] = Chrome.directory()
      assert Chrome.online?(b.id)
    end
  end

  describe "aliases" do
    test "an alias names browsers and resolves to the first one online" do
      {:ok, a} = Chrome.connect("install-a", nil, @device)
      {:ok, b} = Chrome.connect("install-b", nil, @device)
      {:ok, _, _} = Chrome.approve(a.id)
      {:ok, _, _} = Chrome.approve(b.id)

      assert :ok = Aliases.put("qa-chrome", [a.id, b.id])
      assert [%{name: "qa-chrome", browsers: [_, _]}] = Aliases.all()
      assert {:error, {:offline, "qa-chrome", [_, _]}} = Aliases.resolve("qa-chrome")

      :ok = Connection.register(b.id, :approved)
      assert {:ok, %Browser{id: id}} = Aliases.resolve("qa-chrome")
      assert id == b.id

      assert {:error, {:unknown_alias, "nope"}} = Aliases.resolve("nope")
      assert {:error, :no_default} = Aliases.resolve(nil)
      assert :ok = Aliases.set_default("qa-chrome")
      assert {:ok, %Browser{id: ^id}} = Aliases.resolve(nil)
      assert {:error, %{field: :name}} = Aliases.set_default("nope")

      assert {:error, %{field: :browsers}} = Aliases.put("empty", [])
      assert {:error, %{field: :browsers}} = Aliases.put("ghost", ["not-a-browser"])
      assert {:error, %{field: :name}} = Aliases.put("no spaces", [a.id])

      assert :ok = Aliases.delete("qa-chrome")
      assert Aliases.default() == nil
      assert Aliases.all() == []
    end
  end

  describe "the project's definition" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "longx-chrome-def-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(root, ".longx/local"))
      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, project} =
        Longx.Projects.create_project(%{
          name: "browser def #{Path.basename(root)}",
          root_path: root
        })

      %{root: root, project: project}
    end

    test "says what `plug Browser` resolves to on this machine", %{root: root, project: project} do
      describe_with = fn line ->
        File.write!(
          Path.join(root, ".longx/local/agent.exs"),
          "import Longx.Agent.Config\nagent do\n  version 1\n  extends :default\n  #{line}\nend\n"
        )
      end

      # no Browser plug: nothing to say
      describe_with.("plug Environment")
      assert %{browser: nil} = Longx.Projects.agent_definition(project)

      # an alias nobody declared on this machine
      describe_with.("plug Browser, browser: \"qa\", max_tabs: 2")

      assert %{browser: %{alias: "qa", max_tabs: 2, state: "unknown_alias", browser: nil}} =
               Longx.Projects.agent_definition(project)

      # the alias names a paired browser that is not connected now
      {:ok, b} = Chrome.connect("install-def", nil, @device)
      {:ok, _, _} = Chrome.approve(b.id)
      :ok = Aliases.put("qa", [b.id])

      assert %{browser: %{state: "offline", browser: "MJ 的 MacBook · Chrome 153"}} =
               Longx.Projects.agent_definition(project)

      # connected: online
      :ok = Connection.register(b.id, :approved)

      assert %{browser: %{state: "online", browser: "MJ 的 MacBook · Chrome 153"}} =
               Longx.Projects.agent_definition(project)

      # `plug Browser` alone means the default alias, and none is set
      describe_with.("plug Browser, max_tabs: 3")

      assert %{browser: %{alias: nil, max_tabs: 3, state: "no_default", browser: nil}} =
               Longx.Projects.agent_definition(project)

      :ok = Aliases.set_default("qa")
      assert %{browser: %{alias: nil, state: "online"}} = Longx.Projects.agent_definition(project)
    end
  end
end
