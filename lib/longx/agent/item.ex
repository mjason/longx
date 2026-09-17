defmodule Longx.Agent.Item do
  @moduledoc """
  One entry of a thread's transcript (`Longx.Agent.Transcript`): the
  Responses input item (`input`) — a user or assistant message, a
  reasoning item, a function call or its output — and, when it shows in
  the UI, the codex-shaped item (`ui`, replayed as `item/completed`).
  `seq` orders the thread; `turn_id` groups a turn's items for a revert;
  `model` is what produced an assistant item.
  """

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.Agent.Transcript,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "agent_items"
    repo Longx.Repo

    custom_indexes do
      index [:thread_id, :seq]
    end
  end

  actions do
    defaults [:read, :destroy]

    create :append do
      primary? true
      accept [:thread_id, :turn_id, :seq, :kind, :input, :ui, :model]
    end

    read :for_thread do
      argument :thread_id, :string, allow_nil?: false
      filter expr(thread_id == ^arg(:thread_id))
      prepare build(sort: [seq: :asc])
    end

    read :for_turn do
      argument :thread_id, :string, allow_nil?: false
      argument :turn_id, :string, allow_nil?: false
      filter expr(thread_id == ^arg(:thread_id) and turn_id == ^arg(:turn_id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :thread_id, :string, allow_nil?: false, public?: true
    attribute :turn_id, :string, public?: true
    attribute :seq, :integer, allow_nil?: false, public?: true

    attribute :kind, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :user_message,
                    :agent_message,
                    :reasoning,
                    :function_call,
                    :function_call_output,
                    :compaction,
                    :hosted_call,
                    # a UI-only marker (a sub-agent's activity): never model input
                    :activity
                  ]
    end

    attribute :input, :map, allow_nil?: false, public?: true
    attribute :ui, :map, public?: true
    attribute :model, :string, public?: true

    create_timestamp :inserted_at, public?: true
  end
end
