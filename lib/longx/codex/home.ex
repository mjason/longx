defmodule Longx.Codex.Home do
  @moduledoc """
  Our own `CODEX_HOME` for the bundled app-server — never `~/.codex`.

  Codex keeps its config, sqlite state, logs and skills under `CODEX_HOME`.
  We point it at a directory we control and regenerate `config.toml` on every
  boot so codex has exactly one model provider — the Longx gateway — and one
  placeholder model, `longx`. Which real model that means is decided per
  request by `Longx.AI` (see `Longx.AI.Gateway`).

  With `requires_openai_auth = false` codex needs no ChatGPT/OpenAI login at
  all; the only credential it holds is the per-boot gateway token, passed in
  via the environment we hand to `Longx.Shim`.

  Location: `config :longx, Longx.Codex.Home, dir: …` (dev: `./data/codex_home`;
  prod: `$LONGX_DATA_DIR/codex_home`). Not a temp dir — codex refuses to set
  up its PATH helpers there.
  """

  alias Longx.AI.Gateway.Token

  @enforce_keys [:dir, :config_path, :env]
  defstruct [:dir, :config_path, :env]

  @type t :: %__MODULE__{dir: Path.t(), config_path: Path.t(), env: [{String.t(), String.t()}]}

  @provider_id "longx"
  @placeholder_model "longx"

  @doc "`http://127.0.0.1:<endpoint port>/ai/v1` — codex always runs on this host."
  @spec default_gateway_url() :: String.t()
  def default_gateway_url do
    port = LongxWeb.Endpoint.config(:http)[:port]
    "http://127.0.0.1:#{port}/ai/v1"
  end

  @default_tokio_worker_threads 4

  # `config :longx, Longx.Codex.Home, agents:` — codex's [agents] table: how
  # many sub-agents a thread may run at once and how deep they may nest.
  # Every sub-agent is a full model conversation in the same process, so the
  # cap is also a memory / token cap.
  @default_agents [max_concurrent_threads_per_session: 4, max_depth: 2]

  @doc "The `[agents]` limits written into config.toml."
  @spec agents() :: keyword
  def agents do
    :longx
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:agents, [])
    |> then(&Keyword.merge(@default_agents, &1))
  end

  @doc "`config :longx, Longx.Codex.Home, tokio_worker_threads:` (default 4)."
  @spec tokio_worker_threads() :: pos_integer
  def tokio_worker_threads do
    Application.get_env(:longx, __MODULE__, [])
    |> Keyword.get(:tokio_worker_threads, @default_tokio_worker_threads)
  end

  @doc "Configured home directory."
  @spec default_dir() :: Path.t()
  def default_dir do
    Application.get_env(:longx, __MODULE__, [])
    |> Keyword.get(:dir, Path.expand("data/codex_home"))
  end

  @doc """
  Creates the home directory (if needed), (re)writes `config.toml`, and
  returns the paths plus the environment to spawn codex with.

  Options: `:dir` (default `default_dir/0`), `:gateway_url` (default
  `default_gateway_url/0`), `:web_search` — a `t:Longx.AI.web_search_mode/0`
  (default: `Longx.AI.web_search_mode/0`, i.e. whatever is configured),
  `:models` — the catalog entries (`%{slug, context_window}`; default:
  `catalog_models/0`, the AI domain's models with `longx` as the default one).

  Besides `config.toml` it writes `model_catalog.json`: codex knows nothing
  about the models behind the gateway, and for an unknown slug its fallback
  metadata caps the context window at 272k — the per-thread
  `model_context_window` override is clamped to that cap. A catalog entry per
  model (codex's fallback shape, only the window ours) lifts the cap to the
  row's `context_window`.
  """
  @spec prepare(keyword) :: {:ok, t} | {:error, File.posix()}
  def prepare(opts \\ []) do
    %{
      dir: dir,
      config_path: config_path,
      catalog_path: catalog_path,
      config: config,
      catalog: catalog
    } =
      render(opts)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(catalog_path, catalog),
         :ok <- File.write(config_path, config) do
      {:ok,
       %__MODULE__{
         dir: dir,
         config_path: config_path,
         env: [
           {"CODEX_HOME", dir},
           {Token.env_var(), Token.current()},
           # tokio honours this; codex's musl build contends on its allocator
           # with one worker per core on big machines (openai/codex#43170)
           {"TOKIO_WORKER_THREADS", Integer.to_string(tokio_worker_threads())}
         ]
       }}
    end
  end

  @doc """
  What in `dir` no longer matches what `prepare/1` would write now (same
  options): `:models` when a model's window changed or a model was added
  (the catalog codex read at boot is behind), `:config` for the rest of
  `config.toml`. Empty when nothing was written yet — there is no process
  to be behind. codex reads both once, at start: a non-empty answer means
  "restart this project's codex".
  """
  @spec stale(Path.t(), keyword) :: [:models | :config]
  def stale(dir, opts \\ []) do
    %{config_path: config_path, catalog_path: catalog_path, config: config, catalog: catalog} =
      render(Keyword.put(opts, :dir, dir))

    case File.read(config_path) do
      {:ok, _} ->
        for {tag, path, wanted} <- [
              {:models, catalog_path, catalog},
              {:config, config_path, config}
            ],
            File.read(path) != {:ok, wanted},
            do: tag

      {:error, _} ->
        []
    end
  end

  # everything prepare/1 writes, from the options (and the DB for what is not given)
  defp render(opts) do
    dir = Keyword.get(opts, :dir, default_dir()) |> Path.expand()
    gateway_url = Keyword.get(opts, :gateway_url, default_gateway_url())
    web_search = Keyword.get_lazy(opts, :web_search, &Longx.AI.web_search_mode/0)
    memories = Keyword.get_lazy(opts, :memories, &memories?/0)
    models = Keyword.get_lazy(opts, :models, &catalog_models/0)
    catalog_path = Path.join(dir, "model_catalog.json")

    %{
      dir: dir,
      config_path: Path.join(dir, "config.toml"),
      catalog_path: catalog_path,
      config: config_toml(gateway_url, web_search, catalog_path: catalog_path, memories: memories),
      catalog: Jason.encode!(model_catalog(models))
    }
  end

  @doc """
  Whether codex's own memories (per home: extraction, consolidation, the
  `memories.*` tools) are on — `config :longx, Longx.Codex.Home, memories:`,
  default true.
  """
  @spec memories?() :: boolean
  def memories?, do: :longx |> Application.get_env(__MODULE__, []) |> Keyword.get(:memories, true)

  @doc """
  The `config.toml` codex boots with (`catalog_path:` names the model catalog,
  when written; `memories:` codex's own memory pipeline and tools).
  """
  @spec config_toml(String.t(), Longx.AI.web_search_mode(), keyword) :: String.t()
  def config_toml(gateway_url, web_search \\ :disabled, opts \\ []) do
    memories = Keyword.get(opts, :memories, true)

    [
      """
      # Generated by Longx (Longx.Codex.Home) on every boot — do not edit.
      # Codex talks only to the Longx AI gateway; the real model and API key
      # are configured in Longx, never here.

      model_provider = "#{@provider_id}"
      model = "#{@placeholder_model}"
      """,
      catalog_toml(Keyword.get(opts, :catalog_path)),
      web_search_toml(web_search),
      features_toml(web_search, memories),
      memories_toml(memories),
      agents_toml(),
      """

      [model_providers.#{@provider_id}]
      name = "Longx Gateway"
      base_url = "#{gateway_url}"
      env_key = "#{Token.env_var()}"
      wire_api = "responses"
      requires_openai_auth = false
      stream_idle_timeout_ms = 600000
      # capability only: whether web.run is offered is the per-thread
      # `features.standalone_web_search` override (Longx.Codex.Thread)
      supports_standalone_web_search = true
      """
    ]
    |> IO.iodata_to_binary()
  end

  defp catalog_toml(nil), do: []
  defp catalog_toml(path), do: ~s(model_catalog_json = "#{path}"\n)

  ## The model catalog

  # codex's own default for a model it does not know (models-manager
  # `model_info_from_slug`): what a row without a window gets
  @fallback_context_window 272_000

  @doc """
  The catalog entries for the AI domain's models: `longx` (the placeholder
  every thread starts on, sized as the default model) and one per slug.
  """
  @spec catalog_models() :: [%{slug: String.t(), context_window: pos_integer | nil}]
  def catalog_models do
    models = Longx.AI.list_models!()
    default = Enum.find(models, & &1.default)

    [%{slug: @placeholder_model, context_window: default && default.context_window}] ++
      for(
        %{slug: slug, context_window: window} <- models,
        is_binary(slug),
        do: %{slug: slug, context_window: window}
      )
  end

  @doc """
  codex's `model_catalog_json` document: one entry per model in codex's
  fallback shape (unified exec shell, byte truncation, its own base
  instructions — `base_instructions/0`), with `context_window` and
  `max_context_window` from the row.
  """
  @spec model_catalog([%{slug: String.t(), context_window: pos_integer | nil}]) :: map
  def model_catalog(models) do
    instructions = base_instructions()

    %{
      "models" =>
        for %{slug: slug, context_window: window} <- models do
          window = window || @fallback_context_window

          %{
            "slug" => slug,
            "display_name" => slug,
            "description" => nil,
            "supported_reasoning_levels" => [],
            "shell_type" => "unified_exec",
            "visibility" => "none",
            "supported_in_api" => true,
            "priority" => 99,
            "availability_nux" => nil,
            "upgrade" => nil,
            "support_verbosity" => false,
            "default_verbosity" => nil,
            "apply_patch_tool_type" => nil,
            "web_search_tool_type" => "text",
            "truncation_policy" => %{"mode" => "bytes", "limit" => 10_000},
            "context_window" => window,
            "max_context_window" => window,
            "experimental_supported_tools" => [],
            "base_instructions" => instructions
          }
        end
    }
  end

  @base_instructions_path Path.join(:code.priv_dir(:longx), "codex_prompt.md")
  @external_resource @base_instructions_path
  @base_instructions File.read!(@base_instructions_path)

  @doc """
  codex's base instructions (`models-manager/prompt.md` of the pinned
  release, vendored as `priv/codex_prompt.md`): a catalog entry must carry
  instructions, and these keep a catalogued model behaving exactly like an
  unknown one did. Refresh it when bumping codex — the integration suite
  checks it is what the bundled binary embeds.
  """
  @spec base_instructions() :: String.t()
  def base_instructions, do: @base_instructions

  defp agents_toml do
    lines = for {key, value} <- agents(), do: "#{key} = #{value}\n"
    ["\n[agents]\n", lines]
  end

  # :hosted   → the upstream's built-in web_search tool, live web access
  # :standalone → codex's web.run tool, executed by our /alpha/search
  # :disabled → no search tool at all
  defp web_search_toml(:hosted), do: ~s(web_search = "live"\n)
  defp web_search_toml(:standalone), do: ~s(web_search = "live"\n)
  defp web_search_toml(:disabled), do: ~s(web_search = "disabled"\n)

  # one [features] table (TOML refuses a second): codex's memories — the
  # per-home pipeline and its `memories.*` tools — and standalone search
  defp features_toml(web_search, memories) do
    [
      "\n[features]\nmemories = #{memories}\n",
      if(web_search == :standalone, do: "standalone_web_search = true\n", else: [])
    ]
  end

  # the model gets the memory tools (add_ad_hoc_note / list / read / search),
  # not just the "grep MEMORY.md yourself" read path
  defp memories_toml(true), do: "\n[memories]\ndedicated_tools = true\n"
  defp memories_toml(false), do: []
end
