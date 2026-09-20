defmodule Longx.AITest do
  use Longx.DataCase, async: false

  alias Longx.AI

  # `mix test` runs the seeds, so the sandbox starts with the DeepSeek rows;
  # these tests reason about an empty catalogue.
  setup do
    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.SearchProvider, :destroy, %{}, authorize?: false)
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

  describe "discover_models/1 on the Codex backend (a ChatGPT subscription)" do
    test "the catalog's shape (`models[]` with slug, context window, reasoning levels, visibility) is normalised; hidden entries left out; the subscription's headers sent",
         %{} do
      bypass = Bypass.open()

      {:ok, cred} =
        Longx.Credentials.create_oauth2(%{
          name: "chatgpt-disc",
          allowed_hosts: ["localhost"],
          authorize_url: "http://localhost:#{bypass.port}/oauth/authorize",
          token_url: "http://localhost:#{bypass.port}/oauth/token",
          client_id: "app_x",
          fixed_client: true
        })

      {:ok, _} =
        Longx.Credentials.store_tokens(cred, %{
          access_token: "tok",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      provider =
        create_provider!(%{
          slug: "chatgpt-disc",
          base_url: "http://localhost:#{bypass.port}/backend-api/codex",
          credential_id: cred.id
        })

      test_pid = self()

      Bypass.expect_once(bypass, "GET", "/backend-api/codex/models", fn up ->
        send(test_pid, {:upstream, up.req_headers, up.query_string})

        up
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "models" => [
              %{
                "slug" => "gpt-5.6-sol",
                "display_name" => "GPT-5.6-Sol",
                "visibility" => "list",
                "context_window" => 272_000,
                "input_modalities" => ["text", "image"],
                "default_reasoning_level" => "low",
                "supported_reasoning_levels" => [
                  %{"effort" => "low"},
                  %{"effort" => "high"},
                  %{"effort" => "xhigh"}
                ]
              },
              %{
                "slug" => "gpt-daybreak-red-latest",
                "visibility" => "hide",
                "context_window" => 372_000
              },
              %{
                "slug" => "gpt-5.5",
                "display_name" => "GPT-5.5",
                "visibility" => "list",
                "context_window" => 272_000,
                "default_reasoning_level" => "medium",
                "supported_reasoning_levels" => []
              }
            ]
          })
        )
      end)

      assert {:ok, models} = AI.discover_models(provider)
      assert_receive {:upstream, headers, query}
      assert {"authorization", "Bearer tok"} in headers
      assert {"originator", "codex_cli_rs"} in headers
      assert query =~ "client_version="

      assert [
               %{
                 id: "gpt-5.6-sol",
                 name: "GPT-5.6-Sol",
                 context_window: 272_000,
                 reasoning_levels: ["low", "high", "xhigh"],
                 reasoning_effort: "low",
                 image_input: true,
                 installed: false
               },
               %{
                 id: "gpt-5.5",
                 name: "GPT-5.5",
                 context_window: 272_000,
                 reasoning_levels: [],
                 reasoning_effort: nil,
                 image_input: false
               }
             ] = models
    end
  end

  describe "discover_models/1 (the provider's own model list: OpenAI's GET /models standard)" do
    setup do
      bypass = Bypass.open()

      provider =
        create_provider!(%{base_url: "http://localhost:#{bypass.port}/v1", api_key: "sk-ok"})

      %{bypass: bypass, provider: provider}
    end

    test "a plain list (id + owned_by, listenai's shape) and OpenRouter's richer entries, normalised; installed rows flagged",
         %{bypass: bypass, provider: provider} do
      create_model!(provider, %{upstream_id: "deepseek-v4-flash"})
      test_pid = self()

      Bypass.expect_once(bypass, "GET", "/v1/models", fn up ->
        send(test_pid, {:upstream, up.req_headers})

        up
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "object" => "list",
            "data" => [
              %{
                "id" => "deepseek-v4-flash",
                "object" => "model",
                "owned_by" => "deepseek",
                "supported_endpoint_types" => ["openai"]
              },
              %{"id" => "codex-auto-review", "object" => "model", "owned_by" => "openai"},
              %{
                "id" => "deepseek/deepseek-v4.1-flash",
                "name" => "DeepSeek: DeepSeek V4.1 Flash",
                "context_length" => 1_048_576,
                "architecture" => %{"input_modalities" => ["text", "image"]},
                "reasoning" => %{
                  "supported_efforts" => ["max", "high", "low"],
                  "default_effort" => "high"
                }
              },
              %{"id" => "anthropic/claude", "supported_endpoint_types" => ["anthropic"]}
            ]
          })
        )
      end)

      assert {:ok, models} = AI.discover_models(provider)
      assert_receive {:upstream, headers}
      assert {"authorization", "Bearer sk-ok"} in headers

      assert models == [
               %{
                 id: "deepseek-v4-flash",
                 name: "deepseek-v4-flash",
                 owned_by: "deepseek",
                 context_window: nil,
                 reasoning_levels: [],
                 reasoning_effort: nil,
                 image_input: false,
                 installed: true
               },
               %{
                 id: "codex-auto-review",
                 name: "codex-auto-review",
                 owned_by: "openai",
                 context_window: nil,
                 reasoning_levels: [],
                 reasoning_effort: nil,
                 image_input: false,
                 installed: false
               },
               %{
                 id: "deepseek/deepseek-v4.1-flash",
                 name: "DeepSeek: DeepSeek V4.1 Flash",
                 owned_by: nil,
                 context_window: 1_048_576,
                 reasoning_levels: ["low", "high", "max"],
                 reasoning_effort: "high",
                 image_input: true,
                 installed: false
               },
               %{
                 id: "anthropic/claude",
                 name: "anthropic/claude",
                 owned_by: nil,
                 context_window: nil,
                 reasoning_levels: [],
                 reasoning_effort: nil,
                 image_input: false,
                 installed: false
               }
             ]
    end

    test "an error answer or an unreachable host is an error, never a crash; a provider without a key is refused before the call",
         %{bypass: bypass, provider: provider} do
      Bypass.expect_once(bypass, "GET", "/v1/models", fn up ->
        up
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, ~s({"error":{"message":"bad key"}}))
      end)

      assert {:error, {:status, 401, "bad key"}} = AI.discover_models(provider)

      Bypass.down(bypass)
      assert {:error, {:unreachable, _}} = AI.discover_models(provider)

      keyless = create_provider!(%{base_url: "http://localhost:1/v1", api_key: nil})
      assert {:error, {:missing_api_key, _}} = AI.discover_models(keyless)
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

  describe "resolve_target/0 with a credential-backed provider (a ChatGPT subscription)" do
    test "the provider's key is the credential's access token, the account id read off it; without a token the target is missing its key" do
      # a JWT whose payload carries the chatgpt account id (signature never checked here)
      payload =
        Base.url_encode64(
          Jason.encode!(%{
            "https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct-123"},
            "exp" => 4_102_444_800
          }),
          padding: false
        )

      jwt = "eyJhbGciOiJSUzI1NiJ9.#{payload}.sig"

      {:ok, cred} =
        Longx.Credentials.create_oauth2(%{
          name: "chatgpt-test",
          allowed_hosts: ["chatgpt.com"],
          authorize_url: "https://auth.openai.com/oauth/authorize",
          token_url: "https://auth.openai.com/oauth/token",
          client_id: "app_x",
          fixed_client: true
        })

      provider =
        create_provider!(%{
          slug: "chatgpt",
          base_url: "https://chatgpt.com/backend-api/codex",
          credential_id: cred.id
        })

      model = create_model!(provider, %{upstream_id: "gpt-5.6-sol", slug: "gpt-5.6-sol"})
      AI.make_default_model!(model)

      # no login yet: no key
      assert {:error, {:missing_api_key, "chatgpt"}} = AI.resolve_target()

      {:ok, _} =
        Longx.Credentials.store_tokens(cred, %{
          access_token: jwt,
          refresh_token: "rt",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert {:ok,
              %AI.Target{api_key: ^jwt, kind: :openai, chatgpt?: true, account_id: "acct-123"}} =
               AI.resolve_target()

      # a provider with a credential counts as keyed for the chains
      assert {:ok, [%AI.Target{chatgpt?: true}]} = AI.resolve_targets("gpt-5.6-sol")
    end
  end

  describe "prompt_cache_key per provider" do
    test "unset follows the kind (OpenAI on, compatible off); set, the provider's word stands" do
      openai =
        create_provider!(%{slug: "oa", base_url: "https://api.openai.com/v1", api_key: "k"})

      compat =
        create_provider!(%{slug: "cp", base_url: "https://api.deepseek.com/v1", api_key: "k"})

      assert openai.prompt_cache_key == nil and compat.prompt_cache_key == nil

      m1 = create_model!(openai, %{upstream_id: "a", slug: "a"})
      m2 = create_model!(compat, %{upstream_id: "b", slug: "b"})
      assert {:ok, %AI.Target{prompt_cache_key?: true}} = AI.resolve_target("a")
      assert {:ok, %AI.Target{prompt_cache_key?: false}} = AI.resolve_target("b")

      AI.update_provider!(compat, %{prompt_cache_key: true})
      AI.update_provider!(openai, %{prompt_cache_key: false})
      assert {:ok, %AI.Target{prompt_cache_key?: true}} = AI.resolve_target(m2.slug)
      assert {:ok, %AI.Target{prompt_cache_key?: false}} = AI.resolve_target(m1.slug)
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
