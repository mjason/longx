defmodule Longx.AI.Model do
  @moduledoc """
  A model offered by a `Longx.AI.Provider`. `upstream_id` is what the
  provider expects in the request's `model` field. `slug` is the name codex
  sees (per thread / per turn via `model:`); the gateway maps it back. The
  placeholder `longx` means "the global default model" and is reserved.
  """

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.AI,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshTypescript.Resource]

  sqlite do
    table "ai_models"
    repo Longx.Repo
  end

  typescript do
    type_name "Model"
  end

  actions do
    defaults [:read, :destroy]

    # the settings page's delete: the default model stays until another one is made the default
    destroy :delete do
      validate attribute_equals(:default, false), message: "是默认模型，先把另一个模型设为默认"
    end

    create :create do
      primary? true

      accept [
        :name,
        :slug,
        :upstream_id,
        :context_window,
        :provider_id,
        :reasoning_levels,
        :reasoning_effort,
        :reasoning_summary,
        :max_output_tokens
      ]

      change Longx.AI.Model.Changes.DeriveSlug
      validate Longx.AI.Model.Validations.EffortInLevels
    end

    update :update do
      primary? true
      # EffortInLevels reads both attributes together
      require_atomic? false

      accept [
        :name,
        :slug,
        :upstream_id,
        :context_window,
        :reasoning_levels,
        :reasoning_effort,
        :reasoning_summary,
        :max_output_tokens
      ]

      validate Longx.AI.Model.Validations.EffortInLevels
    end

    read :by_slug do
      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(slug == ^arg(:slug))
    end

    read :default do
      get? true
      filter expr(default == true)
    end

    # Longx.AI.check_model/1: one tiny request through the provider, outcome recorded
    action :check_model, :map do
      constraints fields: [
                    ok: [type: :boolean, allow_nil?: false],
                    latency_ms: [type: :integer],
                    error: [type: :string]
                  ]

      argument :id, :uuid, allow_nil?: false

      run fn input, _ ->
        with {:ok, model} <- Ash.get(__MODULE__, input.arguments.id) do
          case Longx.AI.check_model(model) do
            {:ok, %{latency_ms: ms}} -> {:ok, %{ok: true, latency_ms: ms, error: nil}}
            {:error, reason} -> {:ok, %{ok: false, latency_ms: nil, error: inspect(reason)}}
          end
        end
      end
    end

    # Exactly one model is the default: clear the flag everywhere else first.
    update :clear_default do
      change set_attribute(:default, false)
    end

    update :make_default do
      require_atomic? false
      change set_attribute(:default, true)
      change Longx.AI.Model.Changes.ClearOtherDefaults
    end
  end

  validations do
    validate present(:slug), where: [changing(:slug)]

    # "longx" is what codex is configured with; it means the global default
    # (Longx.AI.placeholder_model/0 — a literal here to avoid a compile cycle)
    validate compare(:slug, is_not_equal: "longx"),
      message: "is reserved for the global default",
      where: [changing(:slug)]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    # nullable in the DB only because SQLite cannot add a NOT NULL column later;
    # DeriveSlug + the identity make it effectively required and unique
    attribute :slug, :string, public?: true
    attribute :upstream_id, :string, allow_nil?: false, public?: true

    attribute :context_window, :integer do
      public? true
      allow_nil? false
      default 128_000
      constraints min: 1
    end

    attribute :default, :boolean, allow_nil?: false, default: false, public?: true

    # The reasoning efforts the model offers, in the order a picker shows
    # them (DeepSeek: low / high / max; a model with none declared takes any
    # effort string). Codex's `ReasoningEffort` is a free string, so these
    # are whatever the provider advertises — `none` means thinking off.
    attribute :reasoning_levels, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true

    # Reasoning controls codex applies per thread/turn (`model_reasoning_*`),
    # both optional: nil leaves codex's own default in place. Effort is the
    # model's default level (one of `reasoning_levels` when those are
    # declared); the summary is codex's closed enum.
    attribute :reasoning_effort, :string, public?: true

    attribute :reasoning_summary, :atom do
      public? true
      constraints one_of: [:auto, :concise, :detailed, :none]
    end

    # Cap on one response, applied by the gateway (`max_output_tokens` on the
    # Responses request) when codex sets none; nil = the provider's default.
    attribute :max_output_tokens, :integer do
      public? true
      constraints min: 1
    end

    timestamps public?: true
  end

  relationships do
    belongs_to :provider, Longx.AI.Provider, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
