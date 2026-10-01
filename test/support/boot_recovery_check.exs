# Opt-in real application restart check on a scratch database:
# MIX_ENV=test mix run --no-start test/support/boot_recovery_check.exs
ExUnit.start()

defmodule Longx.RealBootRecoveryCheck do
  use ExUnit.Case

  test "real application restart settles old work before accepting a new turn" do
    alias Longx.{AI, Agent, Jobs, Projects, Watches}
    alias Longx.Projects.{Thread, Turn}

    dir = Path.join(System.tmp_dir!(), "longx-boot-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    Application.put_env(
      :longx,
      Longx.Repo,
      Application.get_env(:longx, Longx.Repo)
      |> Keyword.put(:database, Path.join(dir, "boot.db"))
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
    )

    Application.put_env(:longx, Jobs, dir: Path.join(dir, "jobs"))
    Application.put_env(:longx, Longx.Tls, dir: Path.join(dir, "tls"), public_dns: [])
    System.put_env("RELEASE_NAME", "longx")

    try do
      {:ok, _} = Application.ensure_all_started(:longx)
      {:ok, _} = Application.ensure_all_started(:bypass)
      bypass = Bypass.open()
      me = self()

      Bypass.stub(bypass, "POST", "/api/7/envelope/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:envelope, body})
        Plug.Conn.resp(conn, 200, ~s({"id":"evt"}))
      end)

      Bypass.stub(bypass, "POST", "/v1/responses", fn conn ->
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        Enum.reduce(
          Longx.Test.ResponsesFixture.assistant_message("after restart"),
          conn,
          fn chunk, conn ->
            {:ok, conn} = Plug.Conn.chunk(conn, chunk)
            conn
          end
        )
      end)

      {:ok, _} = Longx.Sentry.set_dsn("http://public@localhost:#{bypass.port}/7")

      provider =
        AI.create_provider!(%{
          name: "boot-check",
          slug: "boot-check",
          base_url: "http://localhost:#{bypass.port}/v1",
          api_key: "test-only"
        })

      model =
        AI.create_model!(%{
          name: "boot-check",
          slug: "boot-check",
          upstream_id: "boot-check",
          provider_id: provider.id
        })

      AI.make_default_model!(model)
      project = Projects.create_project!(%{name: "boot-check", root_path: dir})

      thread =
        Projects.create_thread!(%{
          project_id: project.id,
          kernel_thread_id: "native_boot_check",
          cwd: dir,
          status: :active
        })

      old =
        Projects.create_turn!(%{
          thread_id: thread.id,
          kernel_turn_id: "turn_old_boot",
          user_text: "work before restart",
          started_at: DateTime.utc_now()
        })

      watch =
        Watches.create_watch!(%{
          project_id: project.id,
          name: "boot-check",
          path: Path.join(dir, "boot-check.exs"),
          layer: :local,
          kind: :cron,
          cron: "*/5 * * * *"
        })

      {:ok, _} = Watches.mark_running(watch)
      job_dir = Path.join([dir, "jobs", thread.kernel_thread_id, "old-job"])
      File.mkdir_p!(job_dir)

      File.write!(
        Path.join(job_dir, "job.json"),
        Jason.encode!(%{name: "old-job", cmd: "old work", status: "running", run: "old"})
      )

      :ok = Application.stop(:longx)
      {:ok, _} = Application.ensure_all_started(:longx)

      %{status: :failed, error: "Longx restarted while this turn was running"} =
        Ash.get!(Turn, old.id)

      %{status: :idle} = Ash.get!(Thread, thread.id)
      %{running_since: nil} = Ash.get!(Watches.Watch, watch.id)
      [%{status: "lost"}] = Jobs.list(thread.kernel_thread_id)

      {:ok, fresh} = Projects.send_message(thread, "continue after restart")

      await = fn await, left ->
        case Ash.get!(Turn, fresh.id) do
          %{status: :completed} ->
            :ok

          %{status: :in_progress} when left > 0 ->
            receive do
            after
              50 -> await.(await, left - 1)
            end

          row ->
            raise "the new turn did not complete: #{inspect(Map.take(row, [:status, :error]))}"
        end
      end

      :ok = await.(await, 200)
      :ok = Agent.stop(thread.kernel_thread_id)

      deadline = System.monotonic_time(:millisecond) + 500

      quiet = fn quiet ->
        receive do
          {:envelope, body} ->
            if body =~ old.kernel_turn_id or body =~ fresh.kernel_turn_id,
              do: raise("normal restart emitted a Sentry error")

            quiet.(quiet)
        after
          max(deadline - System.monotonic_time(:millisecond), 0) -> :ok
        end
      end

      :ok = quiet.(quiet)

      IO.puts(
        "PASS: real application restart settled old work, kept Sentry quiet, and completed a new turn"
      )
    after
      Application.stop(:longx)
      File.rm_rf!(dir)
    end
  end
end
