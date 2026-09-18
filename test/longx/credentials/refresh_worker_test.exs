defmodule Longx.Credentials.RefreshWorkerTest do
  @moduledoc "The background refresh: a sweep queues one job per token about to expire; the job refreshes it."
  use Longx.DataCase, async: false
  use Oban.Testing, repo: Longx.Repo, engine: Oban.Engines.Lite, notifier: Oban.Notifiers.PG

  alias Longx.Credentials
  alias Longx.Credentials.{Credential, RefreshWorker}

  setup do
    Ash.bulk_destroy!(Credential, :destroy, %{}, authorize?: false)
    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"

    make = fn name, expires_in, refresh? ->
      {:ok, cred} =
        Credentials.create_oauth2(%{
          name: name,
          allowed_hosts: ["localhost"],
          token_url: base <> "/token",
          client_id: "cid"
        })

      {:ok, cred} =
        Credentials.store_tokens(
          cred,
          %{
            access_token: "at-" <> name,
            expires_at: DateTime.add(DateTime.utc_now(), expires_in, :second)
          }
          |> then(&if(refresh?, do: Map.put(&1, :refresh_token, "rt-" <> name), else: &1))
        )

      cred
    end

    %{bypass: bypass, make: make}
  end

  test "the sweep queues a job for every token expiring within ten minutes that can be refreshed",
       %{make: make} do
    soon = make.("soon", 120, true)
    _far = make.("far", 3600, true)
    _no_refresh = make.("norefresh", 60, false)
    _expired = make.("gone", -60, true)

    assert :ok = perform_job(RefreshWorker, %{})

    ids = all_enqueued(worker: RefreshWorker) |> Enum.map(& &1.args["id"]) |> Enum.sort()
    gone = Credentials.fetch("gone") |> elem(1)
    assert ids == Enum.sort([soon.id, gone.id])
  end

  test "a job refreshes its credential; a refused refresh is on the row and the job still ends",
       %{make: make, bypass: bypass} do
    cred = make.("soon", 120, true)

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{access_token: "at-new", expires_in: 3600}))
    end)

    assert :ok = perform_job(RefreshWorker, %{"id" => cred.id})
    assert {:ok, %{access_token: "at-new", refresh_token: "rt-soon"}} = Credentials.reveal("soon")

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      Plug.Conn.send_resp(conn, 401, "nope")
    end)

    assert :ok = perform_job(RefreshWorker, %{"id" => cred.id})
    assert [%{status: :error}] = Credentials.list()
    # a credential that vanished is no error either
    assert :ok = perform_job(RefreshWorker, %{"id" => Ash.UUID.generate()})
  end
end
