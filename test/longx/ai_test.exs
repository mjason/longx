defmodule Longx.AITest do
  use Longx.DataCase, async: false

  alias Longx.AI

  # `mix test` runs the seeds, so the sandbox starts with the DeepSeek rows;
  # these tests reason about an empty catalogue.
  setup do
    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.SearchProvider, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Tool, :destroy, %{}, authorize?: false)
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp create_provider!(attrs \\ %{}) do
    n = uniq()

    AI.create_provider!(
      Map.merge(
        %{
          name: "Provider #{n}",
          slug: "provider-#{n}",
          base_url: "https://api.example.com/v1",
          api_key: "sk-secret-#{n}"
        },
        attrs
      )
    )
  end

  defp create_model!(provider, attrs \\ %{}) do
    n = uniq()

    AI.create_model!(
      Map.merge(%{name: "Model #{n}", upstream_id: "model-#{n}", provider_id: provider.id}, attrs)
    )
  end

  describe "seeds (priv/repo/seeds.exs)" do
    @seeds Path.expand("priv/repo/seeds.exs")

    test "deepseek-flash (1M, none / low / high / max) is the default; the OpenAI provider is there without models; a chosen value is kept" do
      Code.eval_file(@seeds)
      flash = Enum.find(AI.list_models!(), &(&1.upstream_id == "deepseek-flash"))
      assert flash.context_window == 1_000_000
      assert flash.reasoning_levels == ["none", "low", "high", "max"]
      assert flash.reasoning_effort == "high"
      assert AI.default_model!().id == flash.id
      assert {:ok, %AI.Provider{kind: :openai}} = AI.get_provider_by_slug("openai")
      refute Enum.any?(AI.list_models!(), &(&1.provider.slug == "openai"))

      # a value someone chose is theirs
      AI.update_model!(flash, %{context_window: 200_000})
      Code.eval_file(@seeds)
      assert Ash.get!(AI.Model, flash.id).context_window == 200_000
      # …and a row seeded before levels existed learns them on the next run
      AI.update_model!(Ash.get!(AI.Model, flash.id), %{
        reasoning_levels: [],
        reasoning_effort: nil
      })

      Code.eval_file(@seeds)
      assert Ash.get!(AI.Model, flash.id).reasoning_levels == ["none", "low", "high", "max"]
    end
  end

  describe "providers" do
    test "api_key is stored encrypted and only decrypted when loaded" do
      provider = create_provider!(%{api_key: "sk-plain"})

      assert %Ash.NotLoaded{} = provider.api_key
      assert is_binary(provider.encrypted_api_key)
      refute provider.encrypted_api_key =~ "sk-plain"

      loaded = Ash.load!(provider, :api_key)
      assert loaded.api_key == "sk-plain"
    end

    test "has_api_key? reflects whether a key is set" do
      with_key = create_provider!() |> Ash.load!(:has_api_key?)
      without = create_provider!(%{api_key: nil}) |> Ash.load!(:has_api_key?)

      assert with_key.has_api_key?
      refute without.has_api_key?
    end

    test "slug is unique" do
      provider = create_provider!()

      assert {:error, %Ash.Error.Invalid{}} =
               AI.create_provider(%{name: "dup", slug: provider.slug, base_url: "https://x/v1"})
    end

    test "get_provider_by_slug/1 and update_provider/2 (rotating the key)" do
      provider = create_provider!(%{slug: "deepseek-#{uniq()}"})
      assert {:ok, found} = AI.get_provider_by_slug(provider.slug)
      assert found.id == provider.id

      updated = AI.update_provider!(provider, %{api_key: "sk-rotated"}) |> Ash.load!(:api_key)
      assert updated.api_key == "sk-rotated"
    end

    test "kind: :openai_compatible by default; :openai marks the one provider with real encrypted reasoning" do
      assert create_provider!().kind == :openai_compatible
      assert create_provider!(%{kind: :openai}).kind == :openai

      assert {:error, %Ash.Error.Invalid{}} =
               AI.create_provider(%{
                 name: "x",
                 slug: "k-#{uniq()}",
                 base_url: "https://x/v1",
                 kind: :anthropic
               })
    end

    test "kind is derived from the base_url when not given: api.openai.com is :openai" do
      assert create_provider!(%{base_url: "https://api.openai.com/v1"}).kind == :openai

      assert create_provider!(%{base_url: "https://api.deepseek.com/v1"}).kind ==
               :openai_compatible

      # an explicit choice always wins (a proxy in front of OpenAI is not OpenAI)
      assert create_provider!(%{base_url: "https://api.openai.com/v1", kind: :openai_compatible}).kind ==
               :openai_compatible
    end

    test "request_timeout_ms defaults to ten minutes; max_concurrent_requests is unlimited (nil)" do
      provider = create_provider!()
      assert provider.request_timeout_ms == 600_000
      assert provider.max_concurrent_requests == nil

      tuned = create_provider!(%{request_timeout_ms: 30_000, max_concurrent_requests: 2})
      assert tuned.request_timeout_ms == 30_000
      assert tuned.max_concurrent_requests == 2

      assert {:error, %Ash.Error.Invalid{}} =
               AI.create_provider(%{
                 name: "bad",
                 slug: "bad-#{uniq()}",
                 base_url: "https://x/v1",
                 max_concurrent_requests: 0
               })

      assert {:error, %Ash.Error.Invalid{}} =
               AI.create_provider(%{
                 name: "bad",
                 slug: "bad-#{uniq()}",
                 base_url: "https://x/v1",
                 request_timeout_ms: 10
               })
    end

    test "record_provider_error/2 and clear_provider_error/1 keep the last problem seen on the wire" do
      provider = create_provider!()
      assert provider.last_error == nil
      assert provider.last_error_at == nil

      {:ok, failed} = AI.record_provider_error(provider, "401 Authentication Fails")
      assert failed.last_error == "401 Authentication Fails"
      assert %DateTime{} = failed.last_error_at

      {:ok, cleared} = AI.clear_provider_error(failed)
      assert cleared.last_error == nil
      assert cleared.last_error_at == nil
    end

    test "supports_hosted_web_search defaults to false (only OpenAI runs web_search server-side)" do
      refute create_provider!().supports_hosted_web_search
      assert create_provider!(%{supports_hosted_web_search: true}).supports_hosted_web_search
    end

    test "base_url must be http(s)" do
      assert {:error, %Ash.Error.Invalid{}} =
               AI.create_provider(%{name: "bad", slug: "bad-#{uniq()}", base_url: "ftp://nope"})
    end
  end

  describe "models" do
    test "belong to a provider and default to a 128k context window" do
      provider = create_provider!()
      model = create_model!(provider)

      assert model.provider_id == provider.id
      assert model.context_window == 128_000
      refute model.default
    end

    test "slug is the codex-facing name: derived from upstream_id, unique, never the placeholder" do
      provider = create_provider!()
      model = create_model!(provider, %{upstream_id: "deepseek-flash"})
      assert model.slug == "deepseek-flash"

      assert %{slug: "custom"} = create_model!(provider, %{upstream_id: "gpt-4o", slug: "custom"})

      assert {:error, %Ash.Error.Invalid{}} =
               AI.create_model(%{
                 name: "dup",
                 upstream_id: "x",
                 slug: "deepseek-flash",
                 provider_id: provider.id
               })

      assert {:error, %Ash.Error.Invalid{}} =
               AI.create_model(%{
                 name: "ph",
                 upstream_id: "x",
                 slug: "longx",
                 provider_id: provider.id
               })
    end

    test "get_model_by_slug/1" do
      provider = create_provider!()
      model = create_model!(provider, %{slug: "glm-5-#{uniq()}"})
      assert {:ok, %{id: id}} = AI.get_model_by_slug(model.slug)
      assert id == model.id
    end

    test "default_model/0 is nil until one is chosen, then exclusive" do
      assert {:ok, nil} = AI.default_model()

      provider = create_provider!()
      a = create_model!(provider)
      b = create_model!(provider)

      AI.make_default_model!(a)
      assert {:ok, %{id: id}} = AI.default_model()
      assert id == a.id

      AI.make_default_model!(b)
      assert {:ok, %{id: id}} = AI.default_model()
      assert id == b.id
      refute Ash.get!(AI.Model, a.id).default
    end

    test "reasoning_levels are the efforts the model offers, in order; the default effort must be one of them" do
      provider = create_provider!()

      # nothing declared: the effort is free text (an unknown model's advertised value)
      free = create_model!(provider, %{reasoning_effort: "xhigh"})
      assert free.reasoning_levels == []
      assert free.reasoning_effort == "xhigh"

      flash =
        create_model!(provider, %{
          reasoning_levels: ["low", "high", "max"],
          reasoning_effort: "high"
        })

      assert flash.reasoning_levels == ["low", "high", "max"]

      assert {:error, %Ash.Error.Invalid{errors: [error]}} =
               AI.create_model(%{
                 name: "bad",
                 upstream_id: "bad-#{uniq()}",
                 provider_id: provider.id,
                 reasoning_levels: ["low", "high"],
                 reasoning_effort: "max"
               })

      assert error.field == :reasoning_effort

      # the same rule on update, whichever side changes
      assert {:error, %Ash.Error.Invalid{}} =
               AI.update_model(flash, %{reasoning_effort: "medium"})

      assert {:error, %Ash.Error.Invalid{}} = AI.update_model(flash, %{reasoning_levels: ["low"]})

      assert {:ok, _} =
               AI.update_model(flash, %{
                 reasoning_levels: ["low", "high"],
                 reasoning_effort: "low"
               })

      # levels without a default: codex's own default applies
      assert {:ok, %{reasoning_effort: nil}} =
               AI.create_model(%{
                 name: "no default",
                 upstream_id: "nd-#{uniq()}",
                 provider_id: provider.id,
                 reasoning_levels: ["low", "high"]
               })

      # a level is a non-empty word, no duplicates
      assert {:error, %Ash.Error.Invalid{}} =
               AI.create_model(%{
                 name: "bad",
                 upstream_id: "bad-#{uniq()}",
                 provider_id: provider.id,
                 reasoning_levels: ["low", "low"]
               })

      assert {:error, %Ash.Error.Invalid{}} =
               AI.create_model(%{
                 name: "bad",
                 upstream_id: "bad-#{uniq()}",
                 provider_id: provider.id,
                 reasoning_levels: [""]
               })
    end

    test "reasoning and output settings are per model, all optional" do
      provider = create_provider!()
      plain = create_model!(provider)
      assert plain.reasoning_effort == nil
      assert plain.reasoning_summary == nil
      assert plain.max_output_tokens == nil

      tuned =
        create_model!(provider, %{
          reasoning_effort: "high",
          reasoning_summary: :detailed,
          max_output_tokens: 8_192
        })

      assert tuned.reasoning_effort == "high"
      assert tuned.reasoning_summary == :detailed
      assert tuned.max_output_tokens == 8_192

      # codex's ReasoningSummary is a closed enum; effort is whatever the model advertises
      assert {:error, %Ash.Error.Invalid{}} =
               AI.create_model(%{
                 name: "bad",
                 upstream_id: "bad-#{uniq()}",
                 provider_id: provider.id,
                 reasoning_summary: :verbose
               })

      assert {:error, %Ash.Error.Invalid{}} =
               AI.create_model(%{
                 name: "bad",
                 upstream_id: "bad-#{uniq()}",
                 provider_id: provider.id,
                 max_output_tokens: 0
               })
    end

    test "list_models/0 loads the provider" do
      provider = create_provider!()
      create_model!(provider)

      assert [%{provider: %AI.Provider{}} | _] = AI.list_models!()
    end
  end

  describe "search providers" do
    test "ensure_search_provider/0: the Tavily row exists and is the default — a release seeds nothing, so boot makes it; idempotent, never touches a key" do
      assert {:ok, %AI.SearchProvider{slug: "tavily", default: true} = sp} =
               AI.ensure_search_provider()

      {:ok, _} = AI.update_search_provider(sp, %{api_key: "tvly-keep"})
      assert {:ok, %AI.SearchProvider{id: id}} = AI.ensure_search_provider()
      assert id == sp.id
      assert [%{id: ^id}] = AI.list_search_providers!()
      assert Ash.load!(sp, :api_key).api_key == "tvly-keep"
    end

    test "tavily is the only kind for now and the key is encrypted" do
      sp =
        AI.create_search_provider!(%{
          name: "Tavily",
          slug: "tavily-#{uniq()}",
          kind: :tavily,
          api_key: "tvly-x"
        })

      assert sp.kind == :tavily
      assert sp.base_url == "https://api.tavily.com"
      assert %Ash.NotLoaded{} = sp.api_key
      refute sp.encrypted_api_key =~ "tvly-x"
      assert Ash.load!(sp, :api_key).api_key == "tvly-x"

      assert {:error, %Ash.Error.Invalid{}} =
               AI.create_search_provider(%{
                 name: "Bing",
                 slug: "bing-#{uniq()}",
                 kind: :bing,
                 api_key: "k"
               })
    end

    test "exactly one search provider is the default" do
      a =
        AI.create_search_provider!(%{name: "A", slug: "a-#{uniq()}", kind: :tavily, api_key: "k"})

      b =
        AI.create_search_provider!(%{name: "B", slug: "b-#{uniq()}", kind: :tavily, api_key: "k"})

      assert {:ok, nil} = AI.default_search_provider()
      AI.make_default_search_provider!(a)
      AI.make_default_search_provider!(b)

      assert {:ok, %{id: id}} = AI.default_search_provider()
      assert id == b.id
      refute Ash.get!(AI.SearchProvider, a.id).default
    end

    test "resolve_search_target/0" do
      assert {:error, :no_search_provider} = AI.resolve_search_target()

      keyless = AI.create_search_provider!(%{name: "K", slug: "k-#{uniq()}", kind: :tavily})
      AI.make_default_search_provider!(keyless)
      assert {:error, {:missing_api_key, slug}} = AI.resolve_search_target()
      assert slug == keyless.slug

      sp =
        AI.create_search_provider!(%{
          name: "T",
          slug: "t-#{uniq()}",
          kind: :tavily,
          api_key: "tvly-x"
        })

      AI.make_default_search_provider!(sp)

      assert {:ok,
              %AI.SearchTarget{
                kind: :tavily,
                api_key: "tvly-x",
                base_url: "https://api.tavily.com"
              }} =
               AI.resolve_search_target()
    end

    test "search_configured?/0 is true only with a default provider that has a key" do
      refute AI.search_configured?()

      sp =
        AI.create_search_provider!(%{
          name: "T",
          slug: "t-#{uniq()}",
          kind: :tavily,
          api_key: "tvly-x"
        })

      refute AI.search_configured?()
      AI.make_default_search_provider!(sp)
      assert AI.search_configured?()
    end
  end

  describe "agent tools (which registered tools a thread may get)" do
    test "list_tools/0 mirrors the registry into the DB: every tool present, new ones disabled unless the tool asks otherwise" do
      tools = AI.list_tools!()
      names = Enum.map(tools, &{&1.namespace, &1.name})

      assert {"builtin", "echo"} in names
      assert {"builtin", "thread_status"} in names
      assert {"test", "echo"} in names
      {on, off} = Enum.split_with(tools, & &1.enabled)
      assert Enum.all?(off, &(&1.namespace != "memory"))
      # the memory tools declare enabled_by_default?; nothing else does
      assert Enum.map(on, &{&1.namespace, &1.name}) |> Enum.sort() ==
               [{"memory", "note"}, {"memory", "read"}, {"memory", "search"}]

      # description comes from the code, not the DB
      assert Enum.find(tools, &(&1.name == "thread_status")).description =~ "thread"
    end

    test "only the memory tools are enabled by default, so only they are injected" do
      assert AI.enabled_tool_names() == ["memory.note", "memory.read", "memory.search"]
    end

    test "enable/disable by qualified name, kept across syncs" do
      assert {:ok, %{enabled: true}} = AI.enable_tool("builtin.thread_status")
      assert "builtin.thread_status" in AI.enabled_tool_names()

      # a re-sync (list) must not flip it back
      AI.list_tools!()
      assert "builtin.thread_status" in AI.enabled_tool_names()

      assert {:ok, %{enabled: false}} = AI.disable_tool("builtin.thread_status")
      refute "builtin.thread_status" in AI.enabled_tool_names()
    end

    test "enabling an unregistered tool is an error" do
      assert {:error, :unknown_tool} = AI.enable_tool("nope.nothing")
    end

    test "a tool removed from the code disappears from the list" do
      AI.create_tool!(%{namespace: "gone", name: "tool"})
      refute Enum.any?(AI.list_tools!(), &(&1.namespace == "gone"))
    end
  end

  describe "web_search_mode/0" do
    test ":standalone even when nothing is configured — open fetches pages without a provider" do
      assert AI.web_search_mode() == :standalone
    end

    test ":standalone when the search provider has no key (search_query is told so at call time)" do
      keyless = AI.create_search_provider!(%{name: "K", slug: "k-#{uniq()}", kind: :tavily})
      AI.make_default_search_provider!(keyless)
      assert AI.web_search_mode() == :standalone
    end

    test ":standalone when a search provider with a key is the default" do
      sp =
        AI.create_search_provider!(%{
          name: "T",
          slug: "t-#{uniq()}",
          kind: :tavily,
          api_key: "tvly"
        })

      AI.make_default_search_provider!(sp)
      assert AI.web_search_mode() == :standalone
    end

    test ":hosted when the default model's provider natively supports web search, even with Tavily configured" do
      sp =
        AI.create_search_provider!(%{
          name: "T",
          slug: "t-#{uniq()}",
          kind: :tavily,
          api_key: "tvly"
        })

      AI.make_default_search_provider!(sp)

      openai = create_provider!(%{slug: "openai-#{uniq()}", supports_hosted_web_search: true})
      AI.make_default_model!(create_model!(openai))

      assert AI.web_search_mode() == :hosted
    end

    test "a hosted-capable provider without a key falls back to what is left" do
      openai =
        create_provider!(%{
          slug: "openai-#{uniq()}",
          supports_hosted_web_search: true,
          api_key: nil
        })

      AI.make_default_model!(create_model!(openai))
      assert AI.web_search_mode() == :standalone
    end
  end

  describe "web_search_mode/1 (per model, for the thread being started)" do
    test "follows the model's provider, not the global default" do
      sp =
        AI.create_search_provider!(%{
          name: "T",
          slug: "t-#{uniq()}",
          kind: :tavily,
          api_key: "tvly"
        })

      AI.make_default_search_provider!(sp)

      deepseek = create_provider!(%{slug: "deepseek-#{uniq()}"})
      AI.make_default_model!(create_model!(deepseek, %{slug: "ds-#{uniq()}"}))
      openai = create_provider!(%{slug: "openai-#{uniq()}", supports_hosted_web_search: true})
      gpt = create_model!(openai, %{slug: "gpt-#{uniq()}"})

      assert AI.web_search_mode() == :standalone
      assert AI.web_search_mode(nil) == :standalone
      assert AI.web_search_mode("longx") == :standalone
      assert AI.web_search_mode(gpt.slug) == :hosted
      # unknown model: nothing hosted to rely on, whatever is left applies
      assert AI.web_search_mode("nope") == :standalone
    end
  end

  describe "thread_options/1 and turn_options/1 (what codex gets for a model)" do
    test "the default model contributes its settings but no model name (codex's placeholder stays)" do
      provider = create_provider!()

      model =
        create_model!(provider, %{
          slug: "ds-#{uniq()}",
          context_window: 64_000,
          reasoning_effort: "medium",
          reasoning_summary: :auto,
          max_output_tokens: 4_096
        })

      AI.make_default_model!(model)

      assert {:ok, opts} = AI.thread_options(nil)
      refute Keyword.has_key?(opts, :model)
      assert opts[:model_context_window] == 64_000
      assert opts[:reasoning_effort] == "medium"
      assert opts[:reasoning_summary] == :auto
      assert opts[:web_search] == :standalone
      # not codex's business: the gateway applies it (see resolve_target)
      refute Keyword.has_key?(opts, :max_output_tokens)
      assert {:ok, %AI.Target{max_output_tokens: 4_096}} = AI.resolve_target()

      assert AI.thread_options("longx") == AI.thread_options(nil)

      assert {:ok, turn} = AI.turn_options(nil)
      refute Keyword.has_key?(turn, :model)
      assert turn[:effort] == "medium"
      assert turn[:summary] == :auto
    end

    test "a slug names the model explicitly and unset settings are simply absent" do
      provider = create_provider!(%{supports_hosted_web_search: true})
      model = create_model!(provider, %{slug: "gpt-#{uniq()}", context_window: 400_000})

      assert {:ok, opts} = AI.thread_options(model.slug)
      assert opts[:model] == model.slug
      assert opts[:model_context_window] == 400_000
      assert opts[:web_search] == :hosted
      refute Keyword.has_key?(opts, :reasoning_effort)
      refute Keyword.has_key?(opts, :reasoning_summary)

      assert {:ok, [model: slug]} = AI.turn_options(model.slug)
      assert slug == model.slug
    end

    test "unknown slugs and a missing default are errors" do
      assert {:error, {:unknown_model, "nope"}} = AI.thread_options("nope")
      assert {:error, {:unknown_model, "nope"}} = AI.turn_options("nope")
      assert {:error, :no_default_model} = AI.thread_options(nil)
      assert {:error, :no_default_model} = AI.turn_options(nil)
    end
  end

  describe "complete/3 (one non-streaming answer from the default model — the memory pipeline's model call)" do
    setup do
      bypass = Bypass.open()

      provider =
        create_provider!(%{base_url: "http://localhost:#{bypass.port}/v1", api_key: "sk-ok"})

      model = create_model!(provider, %{upstream_id: "real-model"})
      {:ok, _} = AI.make_default_model(model)
      %{bypass: bypass}
    end

    test "sends instructions + input, hands back the output text", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/v1/responses", fn up ->
        {:ok, raw, up} = Plug.Conn.read_body(up)
        send(test_pid, {:upstream, Jason.decode!(raw)})

        up
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            id: "resp_1",
            object: "response",
            status: "completed",
            output: [
              %{type: "reasoning", summary: []},
              %{
                type: "message",
                role: "assistant",
                content: [%{type: "output_text", text: "- tabs"}]
              }
            ]
          })
        )
      end)

      assert {:ok, "- tabs"} = AI.complete("merge these", "note one", max_output_tokens: 500)
      assert_receive {:upstream, body}
      assert body["model"] == "real-model"
      assert body["instructions"] == "merge these"
      assert body["input"] == "note one"
      assert body["stream"] == false
      assert body["max_output_tokens"] == 500
    end

    test "an upstream error is an error, never a raise", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/responses", fn up ->
        up
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, ~s({"error":{"message":"Authentication Fails"}}))
      end)

      assert {:error, {:status, 401, "Authentication Fails"}} = AI.complete("i", "x")
    end
  end

  describe "check_model/1 (does the provider answer with this key?)" do
    setup do
      bypass = Bypass.open()

      provider =
        create_provider!(%{base_url: "http://localhost:#{bypass.port}/v1", api_key: "sk-ok"})

      model = create_model!(provider, %{upstream_id: "real-model"})
      %{bypass: bypass, provider: provider, model: model}
    end

    test "a 200 records a successful check and clears any earlier error", %{
      bypass: bypass,
      provider: provider,
      model: model
    } do
      {:ok, _} = AI.record_provider_error(provider, "old problem")
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/v1/responses", fn up ->
        {:ok, raw, up} = Plug.Conn.read_body(up)
        send(test_pid, {:upstream, up.req_headers, Jason.decode!(raw)})

        up
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"id":"resp_1","object":"response","status":"completed"}))
      end)

      assert {:ok, %{latency_ms: ms}} = AI.check_model(model)
      assert is_integer(ms) and ms >= 0

      assert_receive {:upstream, headers, body}
      assert {"authorization", "Bearer sk-ok"} in headers
      assert body["model"] == "real-model"
      assert body["stream"] == false
      assert body["store"] == false
      assert is_integer(body["max_output_tokens"])

      {:ok, checked} = AI.get_provider_by_slug(provider.slug)
      assert %DateTime{} = checked.last_checked_at
      assert checked.last_error == nil
    end

    test "a non-2xx is the error, recorded on the provider", %{
      bypass: bypass,
      provider: provider,
      model: model
    } do
      Bypass.expect_once(bypass, "POST", "/v1/responses", fn up ->
        up
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, ~s({"error":{"message":"Authentication Fails"}}))
      end)

      assert {:error, {:status, 401, message}} = AI.check_model(model)
      assert message =~ "Authentication Fails"

      {:ok, checked} = AI.get_provider_by_slug(provider.slug)
      assert %DateTime{} = checked.last_checked_at
      assert checked.last_error =~ "401"
      assert checked.last_error =~ "Authentication Fails"
    end

    test "an unreachable host is {:error, {:unreachable, reason}}", %{
      bypass: bypass,
      provider: provider,
      model: model
    } do
      Bypass.down(bypass)
      assert {:error, {:unreachable, _}} = AI.check_model(model)
      {:ok, checked} = AI.get_provider_by_slug(provider.slug)
      assert checked.last_error =~ "unreachable"
    end

    test "a provider without a key fails before any request", %{model: model, provider: provider} do
      AI.update_provider!(provider, %{api_key: nil})
      assert {:error, {:missing_api_key, _}} = AI.check_model(model)
    end

    test "accepts a slug too", %{bypass: bypass, model: model} do
      Bypass.expect_once(bypass, "POST", "/v1/responses", fn up ->
        Plug.Conn.send_resp(up, 200, "{}")
      end)

      assert {:ok, _} = AI.check_model(model.slug)
      assert {:error, {:unknown_model, "nope"}} = AI.check_model("nope")
    end
  end

  describe "resolve_target/1 (by the model name codex sends)" do
    test "\"longx\" is the global default; a slug picks that model; unknown is an error" do
      provider = create_provider!(%{api_key: "sk-a"})
      default = create_model!(provider, %{upstream_id: "a-default", slug: "a-default"})

      other =
        create_model!(provider, %{upstream_id: "b-other", slug: "b-other", context_window: 32_000})

      AI.make_default_model!(default)

      assert {:ok, %AI.Target{model: "a-default"}} = AI.resolve_target("longx")

      assert {:ok, %AI.Target{model: "b-other", context_window: 32_000}} =
               AI.resolve_target(other.slug)

      assert {:error, {:unknown_model, "nope"}} = AI.resolve_target("nope")
      assert {:ok, %AI.Target{model: "a-default"}} = AI.resolve_target(nil)
    end
  end

  describe "resolve_target/0" do
    test "combines the default model with its provider's credentials" do
      provider = create_provider!(%{base_url: "https://api.deepseek.com/v1", api_key: "sk-ds"})
      model = create_model!(provider, %{upstream_id: "deepseek-v4-pro", context_window: 64_000})
      AI.make_default_model!(model)

      assert {:ok,
              %AI.Target{
                model: "deepseek-v4-pro",
                base_url: "https://api.deepseek.com/v1",
                api_key: "sk-ds",
                context_window: 64_000,
                hosted_web_search?: false,
                kind: :openai_compatible,
                request_timeout_ms: 600_000,
                max_concurrent_requests: nil
              }} = AI.resolve_target()
    end

    test "errors when nothing is configured" do
      assert {:error, :no_default_model} = AI.resolve_target()
    end

    test "errors when the provider has no key" do
      provider = create_provider!(%{api_key: nil})
      model = create_model!(provider)
      AI.make_default_model!(model)

      assert {:error, {:missing_api_key, slug}} = AI.resolve_target()
      assert slug == provider.slug
    end
  end
end
