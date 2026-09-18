defmodule Longx.Notify do
  @moduledoc """
  One feed of what the person should hear about, across projects — what a
  phone raises a notification for: a turn waiting on them (an approval, a
  question), a turn done or failed.

  Events are plain maps with one shape whatever the delivery:

      %{kind, title, body, url, project_id, thread_id, at}

  `kind` is `"approval"` | `"turn_completed"` | `"turn_failed"` | `"watch"`; `url` is
  a path into the SPA (`/p/<slug>/t/<thread id>`),
  the client prefixes its own server address. Delivery today is the
  `notify` channel (`LongxWeb.NotifyChannel`) on every live socket — the
  Android shell's foreground service, a desktop page; APNs for iOS is the
  planned second leg with the same payload.
  """

  alias Phoenix.PubSub

  @topic "notify"
  @kinds ~w(approval turn_completed turn_failed watch)

  @type event :: %{
          kind: String.t(),
          title: String.t(),
          body: String.t(),
          url: String.t(),
          project_id: String.t() | nil,
          thread_id: String.t() | nil,
          at: String.t()
        }

  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Broadcasts an event as `{:notify, event}` on `topic/0`; `at` is stamped here."
  @spec push(map) :: :ok
  def push(%{kind: kind, title: title, body: body, url: url} = event)
      when kind in @kinds and is_binary(title) and is_binary(body) and is_binary(url) do
    event =
      event
      |> Map.take([:kind, :title, :body, :url, :project_id, :thread_id])
      |> Map.put_new(:project_id, nil)
      |> Map.put_new(:thread_id, nil)
      |> Map.put(:at, DateTime.utc_now() |> DateTime.to_iso8601())

    PubSub.broadcast(Longx.PubSub, @topic, {:notify, event})
  end
end
