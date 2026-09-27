defmodule Longx.Chrome.Browser do
  @moduledoc """
  One of the person's browsers, paired through the Longx Chrome extension:
  the extension's own `install_id`, a name (the device's, editable), the
  device, whether the person allowed it (`pending` → `approved` →
  `revoked`), the sha256 of the token it connects with, how many tabs it
  may hold for all projects together, and the origins the agent may open
  in it (`%{"https://example.com" => %{"access" => "allow" | "deny"}}`).
  """

  # No TypeScript type: the page reads browsers through `Longx.Chrome.Bridge`'s
  # maps (`Chrome.directory/0`), never this row — a resource with the
  # AshTypescript extension outside a `typescript_rpc` block is warned about on
  # every RPC call.
  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.Chrome,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "chrome_browsers"
    repo Longx.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :register do
      primary? true
      accept [:install_id, :name, :device]
    end

    # the extension came back: what it says about itself now
    update :seen do
      accept [:name, :device, :last_seen_at]
    end

    update :approve do
      accept [:token_hash]
      change set_attribute(:status, :approved)
      change set_attribute(:approved_at, &DateTime.utc_now/0)
    end

    update :revoke do
      change set_attribute(:status, :revoked)
      change set_attribute(:token_hash, nil)
    end

    # a revoked extension asking again is a request again
    update :ask_again do
      change set_attribute(:status, :pending)
      change set_attribute(:token_hash, nil)
    end

    update :rename do
      accept [:name]
    end

    update :set_max_tabs do
      accept [:max_tabs]
    end

    update :set_origins do
      accept [:origins]
    end

    read :by_install_id do
      argument :install_id, :string, allow_nil?: false
      get? true
      filter expr(install_id == ^arg(:install_id))
    end

    read :by_token_hash do
      argument :token_hash, :string, allow_nil?: false
      get? true
      filter expr(token_hash == ^arg(:token_hash) and status == :approved)
    end

    read :all do
      prepare build(sort: [inserted_at: :asc])
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :install_id, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :device, :map, default: %{}, allow_nil?: false, public?: true

    attribute :status, :atom do
      allow_nil? false
      default :pending
      public? true
      constraints one_of: [:pending, :approved, :revoked]
    end

    attribute :token_hash, :string, sensitive?: true
    attribute :max_tabs, :integer, default: 6, allow_nil?: false, public?: true
    attribute :origins, :map, default: %{}, allow_nil?: false, public?: true
    attribute :last_seen_at, :utc_datetime, public?: true
    attribute :approved_at, :utc_datetime, public?: true

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  identities do
    identity :unique_install_id, [:install_id]
  end
end
