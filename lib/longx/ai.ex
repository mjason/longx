defmodule Longx.AI do
  @moduledoc """
  Model providers, models, and the "which upstream do we talk to" decision
  used by the agent kernel. Requests name a placeholder model (`longx`);
  this domain decides what that means.
  """

  use Ash.Domain, otp_app: :longx, extensions: [AshTypescript.Rpc]

  alias Longx.AI.{Aliases, Model, Provider, SearchProvider, SearchTarget, Target}

  @doc """
  The Tavily row for standalone web search, the default when nothing is
  — created when missing. Seeds call it, and so does the application at
  boot: a release seeds nothing, and without the row the settings page had
  no place to enter the key. A key or an edit already there is kept.
  """
  @spec ensure_search_provider() :: {:ok, SearchProvider.t()} | {:error, term}
  def ensure_search_provider do
    with {:ok, sp} <- tavily_row() do
      case default_search_provider!() do
        nil -> make_default_search_provider(sp)
        _ -> {:ok, sp}
      end
    end
  end

  defp tavily_row do
    case get_search_provider_by_slug("tavily") do
      {:ok, %SearchProvider{} = sp} -> {:ok, sp}
      {:error, _} -> create_search_provider(%{name: "Tavily", slug: "tavily", kind: :tavily})
    end
  end

  # The SPA's typed client (settings pages)
  typescript_rpc do
    resource Provider do
      rpc_action :list_providers, :read
      rpc_action :create_provider, :create
      rpc_action :update_provider, :update
      rpc_action :delete_provider, :delete
      rpc_action :discover_models, :discover_models
    end

    resource Model do
      rpc_action :list_models, :read
      rpc_action :create_model, :create
      rpc_action :update_model, :update
      rpc_action :make_default_model, :make_default
      rpc_action :default_model_setting, :default_model_setting
      rpc_action :set_default_model, :set_default_model
      rpc_action :check_model, :check_model
      rpc_action :model_aliases, :model_aliases
      rpc_action :set_model_alias, :set_model_alias
      rpc_action :delete_model_alias, :delete_model_alias
      rpc_action :delete_model, :delete
    end

    resource SearchProvider do
      rpc_action :list_search_providers, :read
      rpc_action :update_search_provider, :update
    end

    resource Longx.AI.Preset do
      rpc_action :list_presets, :list_presets
      rpc_action :apply_preset, :apply_preset
    end
  end

  resources do
    resource Provider do
      define :create_provider, action: :create
      define :update_provider, action: :update
      define :list_providers, action: :read
      define :get_provider_by_slug, action: :by_slug, args: [:slug]
      define :record_provider_error, action: :record_error, args: [:message]
      define :clear_provider_error, action: :clear_error
      define :record_provider_check, action: :record_check, args: [:error]
    end

    resource Model do
      define :create_model, action: :create
      define :update_model, action: :update
      define :list_models, action: :read, default_options: [load: [:provider]]
      define :default_model, action: :default, default_options: [not_found_error?: false]
      define :make_default_model, action: :make_default
      define :get_model_by_slug, action: :by_slug, args: [:slug]
    end

    resource SearchProvider do
      define :create_search_provider, action: :create
      define :update_search_provider, action: :update
      define :list_search_providers, action: :read
      define :get_search_provider_by_slug, action: :by_slug, args: [:slug]

      define :default_search_provider,
        action: :default,
        default_options: [not_found_error?: false]

      define :make_default_search_provider, action: :make_default
    end

    resource Longx.AI.Preset
  end

  @placeholder_model "longx"

  @doc "The kernel's name for \"the global default model\" (a request's `model` when nothing was chosen)."
  @spec placeholder_model() :: String.t()
  def placeholder_model, do: @placeholder_model

  @doc """
  The upstream a request goes to, by name: `"longx"` (or nothing) is the
  global default model, else a tier / alias or a `Longx.AI.Model` slug.
  Carries the provider's base URL and decrypted key.
  """
  @spec resolve_target(String.t() | nil) ::
          {:ok, Target.t()}
          | {:error,
             :no_default_model | {:unknown_model, String.t()} | {:missing_api_key, String.t()}}
  def resolve_target(nil), do: resolve_target()
  def resolve_target(@placeholder_model), do: resolve_target()

  def resolve_target(slug) when is_binary(slug) do
    case Aliases.resolve(slug) do
      {:ok, [first | _]} -> resolve_slug_target(first)
      :error -> resolve_slug_target(slug)
    end
  end

  defp resolve_slug_target(slug) do
    case get_model_by_slug(slug) do
      {:ok, %Model{} = model} -> target_for(model)
      {:error, _} -> {:error, {:unknown_model, slug}}
    end
  end

  @doc """
  Every target behind a name, in order: a tier or alias gives its chain
  (the first to use, the rest fallbacks), a slug one, nil / `longx` the
  default. A model whose provider has no key is left out of a chain; a
  chain with nobody usable is its first model's error.
  """
  @spec resolve_targets(String.t() | nil) :: {:ok, [Target.t()]} | {:error, term}
  def resolve_targets(name) when is_binary(name) and name != @placeholder_model do
    case Aliases.resolve(name) do
      {:ok, slugs} ->
        results = Enum.map(slugs, &resolve_slug_target/1)

        case for {:ok, target} <- results, do: target do
          [] -> hd(results)
          targets -> {:ok, targets}
        end

      :error ->
        with {:ok, target} <- resolve_slug_target(name), do: {:ok, [target]}
    end
  end

  # the default is a name (a tier, an alias, a slug): its whole chain, like any name
  def resolve_targets(_default) do
    case default_model_name() |> resolve_targets_named() do
      {:ok, targets} -> {:ok, targets}
      {:error, _} -> with({:ok, target} <- resolve_target(), do: {:ok, [target]})
    end
  end

  defp resolve_targets_named(name) when name in [nil, @placeholder_model], do: {:error, :circular}
  defp resolve_targets_named(name), do: resolve_targets(name)

  @doc """
  Every model as the native kernel's prompt names it: slug, name, provider,
  the levels it offers, its default level, whether it is the default — what
  an agent may write as `model "<slug>"` in its description.
  """
  @spec model_choices() :: [
          %{
            slug: String.t(),
            name: String.t(),
            provider: String.t(),
            levels: [String.t()],
            default_level: String.t() | nil,
            default?: boolean
          }
        ]
  def model_choices do
    default = default_model_name()

    aliases =
      for %{name: name, label: label} <- Aliases.all(),
          {:ok, chain} <- [Aliases.resolve(name)] do
        %{
          slug: name,
          name: label,
          provider: "",
          levels: [],
          default_level: nil,
          default?: name == default,
          alias: chain
        }
      end

    models =
      for %Model{slug: slug} = model <- list_models!(), is_binary(slug) do
        %{
          slug: slug,
          name: model.name,
          provider: (model.provider && model.provider.name) || "",
          levels: model.reasoning_levels || [],
          default_level: model.reasoning_effort,
          default?: slug == default
        }
      end
      |> Enum.sort_by(&{!&1.default?, &1.provider, &1.slug})

    aliases ++ models
  end

  @doc "The global default model's target."
  @spec resolve_target() ::
          {:ok, Target.t()} | {:error, :no_default_model | {:missing_api_key, String.t()}}
  def resolve_target do
    with {:ok, %Model{} = model} <- fetch_default_model(), do: target_for(model)
  end

  defp target_for(%Model{} = model) do
    with %Model{provider: %Provider{} = provider} <- Ash.load!(model, provider: [:api_key]),
         {:ok, api_key} <- fetch_api_key(provider) do
      {:ok,
       %Target{
         model: model.upstream_id,
         slug: model.slug,
         base_url: provider.base_url,
         api_key: api_key,
         context_window: model.context_window,
         provider_slug: provider.slug,
         hosted_web_search?:
           if(is_nil(model.hosted_web_search),
             do: provider.supports_hosted_web_search,
             else: model.hosted_web_search
           ),
         kind: provider.kind,
         reasoning_summary: model.reasoning_summary,
         request_timeout_ms: provider.request_timeout_ms,
         max_concurrent_requests: provider.max_concurrent_requests,
         max_output_tokens: model.max_output_tokens
       }}
    end
  end

  ## What a thread is told about a model

  @typedoc "Thread options derived from a model row."
  @type thread_options :: [
          {:model, String.t()}
          | {:model_context_window, pos_integer}
          | {:reasoning_effort, String.t()}
          | {:reasoning_summary, atom}
          | {:web_search, web_search_mode}
        ]

  @doc """
  The per-model options for starting a thread: `nil` /
  `"longx"` is the global default model, whose name is *not* passed (the kernel
  keeps its placeholder); a slug names the model explicitly. Settings left
  unset on the model are absent, so the kernel's defaults apply. The web search
  mode is decided for this model, not the global default. (`max_output_tokens`
  is applied by the gateway, see `Longx.AI.Target`.)
  """
  @spec thread_options(String.t() | nil) ::
          {:ok, thread_options} | {:error, :no_default_model | {:unknown_model, String.t()}}
  def thread_options(slug) do
    with {:ok, model, explicit?} <- fetch_model(slug) do
      opts =
        []
        |> put_if(:model, explicit? && model.slug)
        |> Keyword.put(:model_context_window, model.context_window)
        |> put_if(:reasoning_effort, model.reasoning_effort)
        |> put_if(:reasoning_summary, model.reasoning_summary)
        |> Keyword.put(:web_search, web_search_mode(model))

      {:ok, Enum.reverse(opts)}
    end
  end

  @doc """
  The per-model options for a turn: the model to switch to (absent for the
  default) and its reasoning effort / summary.
  """
  @spec turn_options(String.t() | nil) ::
          {:ok, keyword} | {:error, :no_default_model | {:unknown_model, String.t()}}
  def turn_options(slug) do
    with {:ok, model, explicit?} <- fetch_model(slug) do
      opts =
        []
        |> put_if(:model, explicit? && model.slug)
        |> put_if(:effort, model.reasoning_effort)
        |> put_if(:summary, model.reasoning_summary)

      {:ok, Enum.reverse(opts)}
    end
  end

  @doc """
  Whether `effort` is a reasoning level the model offers: any string for a
  model that declares no levels (a level is free text then),
  one of `reasoning_levels` otherwise. `nil` (the model's default) always is.
  """
  @spec check_effort(String.t() | nil, String.t() | nil) ::
          :ok
          | {:error,
             {:unknown_effort, String.t()} | :no_default_model | {:unknown_model, String.t()}}
  def check_effort(_slug, nil), do: :ok

  def check_effort(slug, effort) when is_binary(effort) do
    with {:ok, model, _explicit?} <- fetch_model(slug) do
      case model.reasoning_levels do
        [] -> :ok
        levels -> if effort in levels, do: :ok, else: {:error, {:unknown_effort, effort}}
      end
    end
  end

  # {:ok, model, named explicitly?}
  @doc """
  What a turn runs on, for the person and the agent to see: `name` the
  tier / alias / slug asked for (nil when nothing was), `slug` the model
  it resolves to (the chain's first), `effort` the level in force (the one
  asked for, else the model's default level), `levels` the model's.
  """
  @spec in_force(String.t() | nil, String.t() | nil) ::
          {:ok,
           %{
             name: String.t() | nil,
             slug: String.t(),
             effort: String.t() | nil,
             levels: [String.t()]
           }}
          | {:error, term}
  def in_force(name, effort) do
    # nothing asked for: the default's name stands where a name would
    asked = if name in [nil, @placeholder_model], do: default_model_name(), else: name

    with {:ok, model, _explicit?} <- fetch_model(asked) do
      slug =
        case Aliases.resolve(asked) do
          {:ok, [first | _]} -> first
          _ -> model.slug
        end

      {:ok,
       %{
         name: if(Aliases.alias?(asked), do: asked),
         slug: slug,
         effort: effort || model.reasoning_effort,
         levels: model.reasoning_levels || []
       }}
    end
  end

  ## The default model: a name

  @default_model_key "default_model"
  @default_model_tier "plus"

  @doc """
  What a session runs on when nobody picks: the saved name — a tier, an
  alias or a slug — and `plus` unless one was saved (an unmapped tier
  means the base row, the one flagged `default`, so a fresh install runs
  on the model its preset chose).
  """
  @spec default_model_name() :: String.t()
  def default_model_name do
    case Longx.System.get_setting(@default_model_key) do
      {:ok, %{value: name}} when is_binary(name) and name != "" -> name
      _ -> @default_model_tier
    end
  end

  @typedoc "The default as the page shows it: the name, what it resolves to now, what kind of name it is."
  @type default_model_info :: %{
          name: String.t(),
          slug: String.t() | nil,
          kind: :tier | :alias | :model
        }

  @spec default_model_info() :: default_model_info
  def default_model_info, do: default_model_info(default_model_name())

  defp default_model_info(name) do
    kind =
      cond do
        String.downcase(name) in Aliases.tiers() -> :tier
        Aliases.alias?(name) -> :alias
        true -> :model
      end

    slug =
      case Aliases.resolve(name) do
        {:ok, [first | _]} -> first
        :error -> if(match?({:ok, _}, get_model_by_slug(name)), do: name)
      end

    %{name: name, slug: slug, kind: kind}
  end

  @doc """
  Saves the default: a tier (`plus` / `pro` / `ultra`), an alias, or a
  model's slug — a slug also becomes the base row (`make_default_model`),
  so an unmapped tier means it too. A name nobody has is refused.
  """
  @spec set_default_model(String.t()) :: {:ok, default_model_info} | {:error, String.t()}
  def set_default_model(name) when is_binary(name) do
    name = String.trim(name)
    tier? = String.downcase(name) in Aliases.tiers()
    name = if tier?, do: String.downcase(name), else: name

    cond do
      tier? or Aliases.alias?(name) ->
        with {:ok, _} <- Longx.System.put_setting(@default_model_key, name),
             do: {:ok, default_model_info(name)}

      true ->
        case get_model_by_slug(name) do
          {:ok, %Model{} = model} ->
            with {:ok, _} <- make_default_model(model),
                 {:ok, _} <- Longx.System.put_setting(@default_model_key, name),
                 do: {:ok, default_model_info(name)}

          {:error, _} ->
            {:error, "没有叫 #{name} 的档位、别名或模型"}
        end
    end
  end

  defp fetch_model(nil), do: fetch_model(@placeholder_model)

  defp fetch_model(@placeholder_model) do
    with {:ok, model} <- fetch_default_model(), do: {:ok, model, false}
  end

  defp fetch_model(slug) when is_binary(slug) do
    # a tier or alias answers as its first model, keeping its own name
    case Aliases.resolve(slug) do
      {:ok, [first | _]} ->
        with {:ok, model, _} <- fetch_model(first), do: {:ok, %{model | slug: slug}, true}

      :error ->
        case get_model_by_slug(slug) do
          {:ok, %Model{} = model} -> {:ok, model, true}
          {:error, _} -> {:error, {:unknown_model, slug}}
        end
    end
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, _key, false), do: opts
  defp put_if(opts, key, value), do: [{key, value} | opts]

  ## Health check

  # enough for the model to answer "ok"; keeps the check cheap
  @check_max_output_tokens 16
  @check_timeout :timer.seconds(30)

  @doc """
  Sends one tiny non-streaming Responses request through the model's provider
  and records the outcome on the provider (`last_checked_at`, `last_error`).
  Answers `{:ok, %{latency_ms: n}}`, `{:error, {:status, code, message}}`
  (the upstream refused), `{:error, {:unreachable, reason}}`, or the usual
  configuration errors before any request is made.
  """
  @spec check_model(Model.t() | String.t()) ::
          {:ok, %{latency_ms: non_neg_integer}} | {:error, term}
  def check_model(%Model{} = model) do
    with {:ok, %Target{} = target} <- target_for(model),
         {:ok, provider} <- get_provider_by_slug(target.provider_slug) do
      result = probe(target)
      {:ok, _} = record_provider_check(provider, check_error(result))
      result
    end
  end

  def check_model(slug) when is_binary(slug) do
    case get_model_by_slug(slug) do
      {:ok, %Model{} = model} -> check_model(model)
      {:error, _} -> {:error, {:unknown_model, slug}}
    end
  end

  @typedoc "A model the provider's own list names (`GET /models`), normalised."
  @type discovered_model :: %{
          id: String.t(),
          name: String.t(),
          owned_by: String.t() | nil,
          context_window: pos_integer | nil,
          reasoning_levels: [String.t()],
          reasoning_effort: String.t() | nil,
          image_input: boolean,
          installed: boolean
        }

  @doc """
  The models the provider's endpoint lists (OpenAI's `GET /models`
  standard: `data[].id`), each with what the entry says about it when it
  says anything — OpenRouter adds `context_length`, `reasoning`
  (efforts + default) and the input modalities; a plain gateway
  (listenai) only `id` and `owned_by`. `installed` marks the ids this
  provider already has a row for. The list is the settings page's "从接口
  获取模型".
  """
  @spec discover_models(Provider.t()) ::
          {:ok, [discovered_model]}
          | {:error,
             {:missing_api_key, String.t()}
             | {:status, integer, term}
             | {:unreachable, String.t()}}
  def discover_models(%Provider{} = provider) do
    provider = Ash.load!(provider, [:api_key, :models])

    with {:ok, api_key} <- fetch_api_key(provider) do
      request =
        Req.new(
          url: String.trim_trailing(provider.base_url, "/") <> "/models",
          auth: {:bearer, api_key},
          retry: false,
          receive_timeout: @check_timeout
        )

      installed = MapSet.new(provider.models, & &1.upstream_id)

      case Req.get(request) do
        {:ok, %Req.Response{status: status, body: %{"data" => entries}}}
        when status in 200..299 and is_list(entries) ->
          {:ok,
           for %{"id" => id} = entry <- entries, is_binary(id) do
             discovered_model(entry, MapSet.member?(installed, id))
           end}

        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:error, {:status, status, "not a model list: #{error_message(body)}"}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:status, status, error_message(body)}}

        {:error, exception} ->
          {:error, {:unreachable, Exception.message(exception)}}
      end
    end
  end

  # the canonical order of efforts, for a list that names them in any order
  @effort_order ~w(none minimal low medium high xhigh max ultra)

  defp discovered_model(%{"id" => id} = entry, installed?) do
    reasoning = entry["reasoning"] || %{}

    levels =
      case reasoning["supported_efforts"] do
        list when is_list(list) ->
          list
          |> Enum.filter(&is_binary/1)
          |> Enum.sort_by(&(Enum.find_index(@effort_order, fn e -> e == &1 end) || 99))

        _ ->
          []
      end

    modalities = get_in(entry, ["architecture", "input_modalities"]) || []

    %{
      id: id,
      name: if(is_binary(entry["name"]) and entry["name"] != "", do: entry["name"], else: id),
      owned_by: entry["owned_by"],
      context_window: if(is_integer(entry["context_length"]), do: entry["context_length"]),
      reasoning_levels: levels,
      reasoning_effort:
        if(is_binary(reasoning["default_effort"]), do: reasoning["default_effort"]),
      image_input: is_list(modalities) and "image" in modalities,
      installed: installed?
    }
  end

  @doc """
  One non-streaming answer from the default model: `instructions` as the
  system side, `input` as the user turn, the output text back. What
  Longx's own model calls use (the memory pipeline); `timeout:` (default
  2 min) and `max_output_tokens:` (default 4096) are the knobs.
  """
  @spec complete(String.t(), String.t(), keyword) ::
          {:ok, String.t()}
          | {:error,
             :no_default_model | {:status, integer, term} | {:unreachable, String.t()} | term}
  def complete(instructions, input, opts \\ []) do
    with {:ok, %Target{} = target} <- resolve_target() do
      request =
        Req.new(
          url: String.trim_trailing(target.base_url, "/") <> "/responses",
          auth: {:bearer, target.api_key},
          json: %{
            model: target.model,
            instructions: instructions,
            input: input,
            max_output_tokens: Keyword.get(opts, :max_output_tokens, 4096),
            stream: false,
            store: false
          },
          retry: false,
          receive_timeout: Keyword.get(opts, :timeout, 120_000)
        )

      case Req.post(request) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, output_text(body)}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:status, status, error_message(body)}}

        {:error, exception} ->
          {:error, {:unreachable, Exception.message(exception)}}
      end
    end
  end

  # the text of every assistant message in a Responses answer
  defp output_text(%{"output" => output}) when is_list(output) do
    for %{"type" => "message", "content" => content} <- output,
        %{"type" => "output_text", "text" => text} <- content,
        into: "",
        do: text
  end

  defp output_text(_), do: ""

  defp probe(%Target{} = target) do
    started = System.monotonic_time(:millisecond)

    request =
      Req.new(
        url: String.trim_trailing(target.base_url, "/") <> "/responses",
        auth: {:bearer, target.api_key},
        json: %{
          model: target.model,
          input: "Reply with the single word: ok",
          max_output_tokens: @check_max_output_tokens,
          stream: false,
          store: false
        },
        retry: false,
        receive_timeout: @check_timeout
      )

    case Req.post(request) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, %{latency_ms: System.monotonic_time(:millisecond) - started}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:status, status, error_message(body)}}

      {:error, exception} ->
        {:error, {:unreachable, Exception.message(exception)}}
    end
  end

  defp error_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp error_message(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp error_message(body), do: body |> inspect() |> String.slice(0, 500)

  defp check_error({:ok, _}), do: nil
  defp check_error({:error, {:status, status, message}}), do: "#{status} #{message}"
  defp check_error({:error, {:unreachable, reason}}), do: "unreachable: #{reason}"

  @doc "The standalone web-search backend (`Plugs.WebSearch`): the default search provider and its key."
  @spec resolve_search_target() ::
          {:ok, SearchTarget.t()} | {:error, :no_search_provider | {:missing_api_key, String.t()}}
  def resolve_search_target do
    with {:ok, %SearchProvider{} = sp} <- fetch_default_search_provider(),
         %SearchProvider{} = sp <- Ash.load!(sp, :api_key),
         {:ok, api_key} <- fetch_api_key(sp) do
      {:ok,
       %SearchTarget{
         kind: sp.kind,
         base_url: sp.base_url,
         api_key: api_key,
         provider_slug: sp.slug
       }}
    end
  end

  @doc "Whether standalone web search is configured at all."
  @spec search_configured?() :: boolean
  def search_configured?, do: match?({:ok, _}, resolve_search_target())

  @typedoc """
  How the kernel does web search, decided from what is configured:

    * `:hosted` — the upstream runs the Responses API's built-in `web_search`
      tool itself (OpenAI); nothing for us to do
    * `:standalone` — the kernel's own `web_search` tool over `Longx.AI.Search`:
      `open` renders pages with the bundled browser (`Longx.Browser`) and needs
      no provider, `search_query` needs the default `SearchProvider` (told so
      otherwise) — so this is the mode whenever search is not hosted
    * `:disabled` — no search tool offered at all (an explicit choice; the
      resolver never picks it on its own any more)
  """
  @type web_search_mode :: :hosted | :standalone | :disabled

  @doc "See `t:web_search_mode/0`, for the global default model."
  @spec web_search_mode() :: web_search_mode
  def web_search_mode, do: web_search_mode(resolve_target(), resolve_search_target())

  @doc """
  The web search mode for one model (by slug; `nil`/`"longx"` = the default),
  what a thread started on that model gets as config override. An unknown
  slug has nothing hosted to offer, so what is left applies.
  """
  @spec web_search_mode(String.t() | nil | Model.t()) :: web_search_mode
  def web_search_mode(%Model{} = model),
    do: web_search_mode(target_for(model), resolve_search_target())

  def web_search_mode(slug), do: web_search_mode(resolve_target(slug), resolve_search_target())

  defp web_search_mode({:ok, %Target{hosted_web_search?: true}}, _search), do: :hosted
  defp web_search_mode(_target, _search), do: :standalone

  defp fetch_default_search_provider do
    case default_search_provider() do
      {:ok, nil} -> {:error, :no_search_provider}
      other -> other
    end
  end

  # the default's name resolved to a row (a tier's or alias's first model),
  # else the base row — the one flagged `default`
  defp fetch_default_model do
    name = default_model_name()

    concrete =
      case Aliases.resolve(name) do
        {:ok, [first | _]} -> get_model_by_slug(first)
        :error -> get_model_by_slug(name)
      end

    case concrete do
      {:ok, %Model{} = model} ->
        {:ok, model}

      _ ->
        case default_model() do
          {:ok, nil} -> {:error, :no_default_model}
          other -> other
        end
    end
  end

  defp fetch_api_key(%{api_key: key}) when is_binary(key) and key != "", do: {:ok, key}
  defp fetch_api_key(%{slug: slug}), do: {:error, {:missing_api_key, slug}}
end
