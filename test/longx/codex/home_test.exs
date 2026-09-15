defmodule Longx.Codex.HomeTest do
  use Longx.DataCase, async: false

  alias Longx.AI.Gateway.Token
  alias Longx.Codex.Home

  setup do
    Ash.bulk_destroy!(Longx.AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Longx.AI.Provider, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Longx.AI.SearchProvider, :destroy, %{}, authorize?: false)

    dir = Path.join(System.tmp_dir!(), "longx-codex-home-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "prepare/1 creates the directory and writes a config pointing codex at our gateway", %{
    dir: dir
  } do
    {:ok, home} = Home.prepare(dir: dir, gateway_url: "http://127.0.0.1:4242/ai/v1")

    assert home.dir == dir
    assert File.dir?(dir)
    assert home.config_path == Path.join(dir, "config.toml")

    config = File.read!(home.config_path)
    assert config =~ ~s(model_provider = "longx")
    assert config =~ ~s(model = "longx")
    assert config =~ ~s([model_providers.longx])
    assert config =~ ~s(base_url = "http://127.0.0.1:4242/ai/v1")
    assert config =~ ~s(env_key = "LONGX_GATEWAY_TOKEN")
    assert config =~ ~s(wire_api = "responses")
    assert config =~ ~s(requires_openai_auth = false)
  end

  test "web search is standalone by default: open fetches pages without any provider", %{
    dir: dir
  } do
    {:ok, home} = Home.prepare(dir: dir, gateway_url: "http://127.0.0.1:4242/ai/v1")
    config = File.read!(home.config_path)

    refute config =~ ~s(web_search = "disabled")
    # the provider is always declared capable: threads switch modes per model
    assert config =~ "supports_standalone_web_search = true"
    assert config =~ "[features]\nmemories = true\nstandalone_web_search = true"

    # an explicit :disabled still turns the tool off entirely
    {:ok, off} =
      Home.prepare(dir: dir, gateway_url: "http://127.0.0.1:4242/ai/v1", web_search: :disabled)

    assert File.read!(off.config_path) =~ ~s(web_search = "disabled")
  end

  test "web_search: :standalone routes codex's web.run tool to our /alpha/search", %{dir: dir} do
    {:ok, home} =
      Home.prepare(dir: dir, gateway_url: "http://127.0.0.1:4242/ai/v1", web_search: :standalone)

    config = File.read!(home.config_path)

    refute config =~ ~s(web_search = "disabled")
    assert config =~ "supports_standalone_web_search = true"
    assert config =~ "[features]\nmemories = true\nstandalone_web_search = true"
  end

  test "web_search: :hosted lets codex use the upstream's own web_search tool", %{dir: dir} do
    {:ok, home} =
      Home.prepare(dir: dir, gateway_url: "http://127.0.0.1:4242/ai/v1", web_search: :hosted)

    config = File.read!(home.config_path)

    assert config =~ ~s(web_search = "live")
    refute config =~ "\nstandalone_web_search = true"
  end

  test "codex's own memories are on for every home (its read path and pipeline, not its tools), in one [features] table with search",
       %{dir: dir} do
    {:ok, home} = Home.prepare(dir: dir, gateway_url: "http://127.0.0.1:4242/ai/v1")
    config = File.read!(home.config_path)
    assert config =~ "[features]\nmemories = true\nstandalone_web_search = true\n"
    assert config =~ "[memories]\ndedicated_tools = false\n"
    # one [features] table: TOML refuses a second
    assert length(String.split(config, "[features]")) == 2

    {:ok, home} =
      Home.prepare(dir: dir, gateway_url: "http://127.0.0.1:4242/ai/v1", memories: false)

    config = File.read!(home.config_path)
    assert config =~ "[features]\nmemories = false\n"
    refute config =~ "[memories]"

    {:ok, home} =
      Home.prepare(dir: dir, gateway_url: "http://127.0.0.1:4242/ai/v1", web_search: :disabled)

    assert File.read!(home.config_path) =~ "[features]\nmemories = true\n"
  end

  test "the [agents] limits (sub-agents per session, depth) come from config", %{dir: dir} do
    {:ok, home} = Home.prepare(dir: dir, gateway_url: "http://127.0.0.1:4242/ai/v1")
    config = File.read!(home.config_path)
    assert config =~ "[agents]\nmax_concurrent_threads_per_session = 4\nmax_depth = 2\n"
  end

  test "prepare/1 writes a model catalog so codex knows each model's window (its fallback caps every unknown model at 272k)",
       %{dir: dir} do
    {:ok, home} =
      Home.prepare(
        dir: dir,
        gateway_url: "http://127.0.0.1:4242/ai/v1",
        models: [
          %{slug: "longx", context_window: 1_000_000},
          %{slug: "deepseek-flash", context_window: 1_000_000},
          %{slug: "glm-5", context_window: nil}
        ]
      )

    catalog_path = Path.join(dir, "model_catalog.json")
    assert File.read!(home.config_path) =~ ~s(model_catalog_json = "#{catalog_path}")
    assert %{"models" => models} = Jason.decode!(File.read!(catalog_path))
    assert Enum.map(models, & &1["slug"]) == ["longx", "deepseek-flash", "glm-5"]

    [longx, _flash, glm] = models
    assert longx["context_window"] == 1_000_000
    assert longx["max_context_window"] == 1_000_000
    # a model without a known window keeps codex's own default
    assert glm["context_window"] == 272_000
    # the rest of an entry is codex's fallback metadata: same shell, truncation,
    # instructions — only the window differs from an unknown model
    assert longx["shell_type"] == "unified_exec"
    assert longx["truncation_policy"] == %{"mode" => "bytes", "limit" => 10_000}
    assert longx["supported_reasoning_levels"] == []
    assert longx["base_instructions"] == Home.base_instructions()

    assert String.starts_with?(
             longx["base_instructions"],
             "You are a coding agent running in the Codex CLI"
           )
  end

  test "without models given, the catalog is the AI domain's models with `longx` as the default one",
       %{dir: dir} do
    provider =
      Longx.AI.create_provider!(%{
        name: "P",
        slug: "p-#{System.unique_integer([:positive])}",
        base_url: "https://api.deepseek.com/v1",
        api_key: "k"
      })

    a =
      Longx.AI.create_model!(%{
        name: "A",
        upstream_id: "a-model",
        context_window: 1_000_000,
        provider_id: provider.id
      })

    Longx.AI.create_model!(%{
      name: "B",
      upstream_id: "b-model",
      context_window: 200_000,
      provider_id: provider.id
    })

    Longx.AI.make_default_model!(a)

    {:ok, _home} = Home.prepare(dir: dir, gateway_url: "http://127.0.0.1:4242/ai/v1")
    %{"models" => models} = Jason.decode!(File.read!(Path.join(dir, "model_catalog.json")))

    assert Enum.map(models, &{&1["slug"], &1["context_window"]}) == [
             {"longx", 1_000_000},
             {"a-model", 1_000_000},
             {"b-model", 200_000}
           ]
  end

  test "a model's reasoning levels and default level go into its catalog entry (codex's own model picker shows them)",
       %{dir: dir} do
    {:ok, _} =
      Home.prepare(
        dir: dir,
        gateway_url: "http://127.0.0.1:4242/ai/v1",
        models: [
          %{
            slug: "longx",
            context_window: 1_000_000,
            reasoning_levels: ["low", "high", "max"],
            reasoning_effort: "high"
          },
          %{slug: "turbo", context_window: 200_000, reasoning_levels: [], reasoning_effort: nil},
          %{slug: "free", context_window: nil, reasoning_levels: [], reasoning_effort: "xhigh"}
        ]
      )

    %{"models" => [longx, turbo, free]} =
      Jason.decode!(File.read!(Path.join(dir, "model_catalog.json")))

    assert Enum.map(longx["supported_reasoning_levels"], & &1["effort"]) == ["low", "high", "max"]
    assert Enum.all?(longx["supported_reasoning_levels"], &is_binary(&1["description"]))
    assert longx["default_reasoning_level"] == "high"

    # no levels: nothing declared, codex's default effort
    assert turbo["supported_reasoning_levels"] == []
    refute Map.has_key?(turbo, "default_reasoning_level")

    # a default without levels still counts as the default
    assert free["supported_reasoning_levels"] == []
    assert free["default_reasoning_level"] == "xhigh"
  end

  test "the catalog from the AI domain carries each row's levels, `longx` taking the default model's",
       %{dir: dir} do
    provider =
      Longx.AI.create_provider!(%{
        name: "P",
        slug: "p-#{System.unique_integer([:positive])}",
        base_url: "https://api.deepseek.com/v1",
        api_key: "k"
      })

    a =
      Longx.AI.create_model!(%{
        name: "A",
        upstream_id: "a-model",
        context_window: 1_000_000,
        reasoning_levels: ["low", "high"],
        reasoning_effort: "low",
        provider_id: provider.id
      })

    Longx.AI.make_default_model!(a)

    {:ok, _home} = Home.prepare(dir: dir, gateway_url: "http://127.0.0.1:4242/ai/v1")

    %{"models" => [longx, a_entry]} =
      Jason.decode!(File.read!(Path.join(dir, "model_catalog.json")))

    for entry <- [longx, a_entry] do
      assert Enum.map(entry["supported_reasoning_levels"], & &1["effort"]) == ["low", "high"]
      assert entry["default_reasoning_level"] == "low"
    end

    # editing the levels makes the catalog on disk stale, like a window edit
    Longx.AI.update_model!(a, %{reasoning_levels: ["low", "high", "max"]})
    assert Home.stale(dir, gateway_url: "http://127.0.0.1:4242/ai/v1") == [:models]
  end

  test "stale/2 says which of the written files no longer match what prepare would write", %{
    dir: dir
  } do
    models = [%{slug: "longx", context_window: 128_000}]
    {:ok, _} = Home.prepare(dir: dir, gateway_url: "http://127.0.0.1:4242/ai/v1", models: models)
    assert Home.stale(dir, gateway_url: "http://127.0.0.1:4242/ai/v1", models: models) == []

    # a model's window changed → the catalog on disk is behind
    assert Home.stale(dir,
             gateway_url: "http://127.0.0.1:4242/ai/v1",
             models: [%{slug: "longx", context_window: 1_000_000}]
           ) == [:models]

    # the search mode changed → the config is behind
    assert Home.stale(dir,
             gateway_url: "http://127.0.0.1:4242/ai/v1",
             models: models,
             web_search: :hosted
           ) == [:config]

    # codex appends its own sections to config.toml (a trusted project, on
    # first use): what we wrote is still there, so nothing is stale
    File.write!(
      Path.join(dir, "config.toml"),
      File.read!(Path.join(dir, "config.toml")) <>
        "\n[projects.\"/home/mj/dev/python/jbt_lab\"]\ntrust_level = \"trusted\"\n"
    )

    assert Home.stale(dir, gateway_url: "http://127.0.0.1:4242/ai/v1", models: models) == []

    # nothing written yet: nothing is stale (there is no process to restart)
    assert Home.stale(Path.join(dir, "nope"),
             gateway_url: "http://127.0.0.1:4242/ai/v1",
             models: models
           ) == []
  end

  test "without an explicit option the mode comes from Longx.AI.web_search_mode/0", %{dir: dir} do
    # nothing configured in the (sandboxed, cleared) DB → standalone (open needs no provider)
    {:ok, home} = Home.prepare(dir: dir, gateway_url: "http://127.0.0.1:4242/ai/v1")

    assert File.read!(home.config_path) =~
             "[features]\nmemories = true\nstandalone_web_search = true"
  end

  test "the env caps codex's tokio worker threads (musl allocator contention on many cores)",
       %{dir: dir} do
    {:ok, home} = Home.prepare(dir: dir, gateway_url: "http://127.0.0.1:4242/ai/v1")
    assert {"TOKIO_WORKER_THREADS", "4"} in home.env
  end

  test "the env hands codex the home and the current gateway token", %{dir: dir} do
    {:ok, home} = Home.prepare(dir: dir, gateway_url: "http://127.0.0.1:4242/ai/v1")

    assert {"CODEX_HOME", dir} in home.env
    assert {"LONGX_GATEWAY_TOKEN", Token.current()} in home.env
  end

  test "prepare/1 rewrites a stale config every time", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "config.toml"), ~s(model_provider = "openai"\n))

    {:ok, home} = Home.prepare(dir: dir, gateway_url: "http://127.0.0.1:4242/ai/v1")
    config = File.read!(home.config_path)

    assert config =~ ~s(model_provider = "longx")
    refute config =~ ~s("openai")
  end

  test "the default gateway url is loopback on the endpoint's port" do
    port = LongxWeb.Endpoint.config(:http)[:port]
    assert Home.default_gateway_url() == "http://127.0.0.1:#{port}/ai/v1"
  end

  test "config.toml has a comment saying it is generated", %{dir: dir} do
    {:ok, home} = Home.prepare(dir: dir, gateway_url: "http://127.0.0.1:4242/ai/v1")
    assert File.read!(home.config_path) |> String.starts_with?("# Generated by Longx")
  end

  describe "passthrough: host paths let into the bubblewrap sandbox" do
    @gateway "http://127.0.0.1:4242/ai/v1"

    test "prepare/1 puts the bwrap wrapper on codex's PATH with the real bwrap and the paths in its env; stale/2 sees a change; none → nothing",
         %{dir: dir} do
      paths = ["/dev/dxg", "/var/run/x.sock"]

      {:ok, home} =
        Home.prepare(dir: dir, gateway_url: @gateway, passthrough: paths, bwrap: "/usr/bin/true")

      env = Map.new(home.env)
      assert String.starts_with?(env["PATH"], Path.join(dir, "bin") <> ":")
      assert env["LONGX_BWRAP_REAL"] == "/usr/bin/true"
      assert env["LONGX_BWRAP_PASSTHROUGH"] == "/dev/dxg\n/var/run/x.sock"

      link = Path.join(dir, "bin/bwrap")
      assert {:ok, target} = File.read_link(link)
      assert Path.basename(target) == Longx.Platform.bwrapx_executable_name()

      assert Home.stale(dir, gateway_url: @gateway, passthrough: paths) == []
      assert Home.stale(dir, gateway_url: @gateway, passthrough: ["/dev/dxg"]) == [:passthrough]
      assert Home.stale(dir, gateway_url: @gateway) == [:passthrough]

      {:ok, home} = Home.prepare(dir: dir, gateway_url: @gateway)
      refute File.exists?(link)
      refute Map.has_key?(Map.new(home.env), "PATH")
      refute Map.has_key?(Map.new(home.env), "LONGX_BWRAP_REAL")
      assert Home.stale(dir, gateway_url: @gateway) == []
    end

    test "the wrapper itself: --help goes straight through, a sandbox command line gets the binds after --dev /dev",
         %{dir: dir} do
      # a stand-in for the real bwrap that prints the arguments it was given
      fake = Path.join(dir, "fake-bwrap")
      File.mkdir_p!(dir)
      File.write!(fake, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n")
      File.chmod!(fake, 0o755)

      {:ok, home} =
        Home.prepare(
          dir: dir,
          gateway_url: @gateway,
          passthrough: ["/dev/dxg", "/x.sock"],
          bwrap: fake
        )

      env = Enum.filter(home.env, fn {k, _} -> String.starts_with?(k, "LONGX_BWRAP") end)
      bwrap = Path.join(dir, "bin/bwrap")

      {out, 0} = System.cmd(bwrap, ["--help"], env: env)
      assert String.split(out, "\n", trim: true) == ["--help"]

      {out, 0} =
        System.cmd(bwrap, ~w(--ro-bind / / --dev /dev --bind /tmp /tmp -- /bin/true), env: env)

      assert String.split(out, "\n", trim: true) ==
               ~w(--ro-bind / / --dev /dev --dev-bind /dev/dxg /dev/dxg --bind /x.sock /x.sock --bind /tmp /tmp -- /bin/true)
    end
  end
end
