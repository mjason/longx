defmodule Longx.Tools.Builtin.ThreadStatus do
  @moduledoc "Lets the agent inspect the Longx-side view of its own thread."
  @behaviour Longx.Codex.Tool

  alias Longx.Codex.Tool.Context

  @impl true
  def name, do: "thread_status"

  @impl true
  def namespace, do: "builtin"

  @impl true
  def description do
    "Describes the current thread as Longx sees it: turn status, number of items by type, " <>
      "pending approval requests waiting on the user, and token usage. Use it to check whether " <>
      "something you asked the user is still unanswered."
  end

  @impl true
  def input_schema,
    do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @impl true
  def call(_args, %Context{snapshot: snapshot}) when is_function(snapshot, 0) do
    snap = snapshot.()

    counts =
      snap.items
      |> Enum.frequencies_by(& &1["type"])
      |> Enum.map_join(", ", fn {type, n} -> "#{type}: #{n}" end)

    pending =
      case snap.pending_requests do
        [] -> "none"
        reqs -> Enum.map_join(reqs, "; ", &"#{&1.method} (#{&1.id})")
      end

    {:ok,
     """
     thread: #{snap.thread_id}
     turn: #{inspect(snap.turn && snap.turn["status"])}
     status: #{inspect(snap.status)}
     items: #{if counts == "", do: "none", else: counts}
     pending requests: #{pending}
     token usage: #{inspect(snap.token_usage)}
     """}
  end

  def call(_args, _ctx), do: {:error, "no thread snapshot available in this context"}
end
