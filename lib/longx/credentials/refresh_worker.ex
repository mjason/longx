defmodule Longx.Credentials.RefreshWorker do
  @moduledoc """
  Keeps OAuth2 tokens fresh in the background. Oban's cron runs the
  sweep every five minutes (`config :longx, Oban`): every credential
  whose access token expires within `within_seconds` (10 minutes) and
  has a refresh token gets one job of its own (unique per credential, so
  two sweeps never refresh the same one twice), and that job runs
  `Longx.Credentials.OAuth.refresh/1` — an error lands on the row as
  `last_error` and the job is not retried (the next sweep tries again;
  the settings page shows the status).
  """

  use Oban.Worker, queue: :credentials, max_attempts: 1, unique: [period: 300, keys: [:id]]

  alias Longx.Credentials

  @within_seconds 10 * 60

  @impl Oban.Worker
  # the sweep: one job per credential due
  def perform(%Oban.Job{args: args}) when map_size(args) == 0 do
    jobs =
      @within_seconds
      |> Credentials.expiring()
      |> Enum.map(&new(%{"id" => &1.id}))

    Oban.insert_all(jobs)
    :ok
  end

  # one credential
  def perform(%Oban.Job{args: %{"id" => id}}) do
    case Ash.get(Credentials.Credential, id) do
      {:ok, cred} ->
        case Credentials.refresh(cred) do
          {:ok, _} -> :ok
          # remembered on the row; nothing a retry would change right now
          {:error, _reason} -> :ok
        end

      {:error, _} ->
        :ok
    end
  end

  @doc "How far ahead the sweep looks (seconds)."
  @spec within_seconds() :: pos_integer
  def within_seconds, do: @within_seconds
end
