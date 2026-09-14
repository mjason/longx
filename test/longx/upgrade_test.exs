defmodule Longx.UpgradeTest do
  @moduledoc """
  Self-upgrade from GitHub releases: the check (with and without a token),
  and the apply — download, verify, swap the app directory, restart —
  against Bypass playing GitHub and a fake install tree on disk.
  """
  use Longx.DataCase, async: false

  alias Longx.Upgrade

  @version "9.9.9"

  setup do
    bypass = Bypass.open()
    root = Path.join(System.tmp_dir!(), "longx-upgrade-#{System.unique_integer([:positive])}")
    app = Path.join(root, "app")
    File.mkdir_p!(Path.join(app, "bin"))
    File.write!(Path.join(app, "bin/longx"), "#!/bin/sh\necho longx 0.0.1\n")
    File.chmod!(Path.join(app, "bin/longx"), 0o755)
    marker = Path.join(root, "restarted")

    previous = Application.get_env(:longx, Upgrade, [])

    Application.put_env(:longx, Upgrade,
      repo: "mjason/longx",
      api_url: "http://127.0.0.1:#{bypass.port}",
      app_dir: app,
      restart_command: ["sh", "-c", "echo yes > #{marker}"],
      tick: nil
    )

    Upgrade.reset()
    Phoenix.PubSub.subscribe(Longx.PubSub, Upgrade.topic())

    on_exit(fn ->
      Application.put_env(:longx, Upgrade, previous)
      Upgrade.reset()
      File.rm_rf!(root)
    end)

    %{bypass: bypass, root: root, app: app, marker: marker}
  end

  # a release tarball the way the workflow packs it: one top directory
  defp tarball!(root, version) do
    name = "longx-#{version}-linux-#{Upgrade.arch()}.tar.gz"
    build = Path.join(root, "build")
    top = Path.join(build, "longx-#{version}")
    File.mkdir_p!(Path.join(top, "bin"))
    File.write!(Path.join(top, "bin/longx"), "#!/bin/sh\necho longx #{version}\n")
    File.chmod!(Path.join(top, "bin/longx"), 0o755)
    path = Path.join(root, name)
    {_, 0} = System.cmd("tar", ["-C", build, "-czf", path, "longx-#{version}"])
    sha = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
    {name, path, "#{sha}  #{name}\n"}
  end

  defp release_json(bypass, version, assets) do
    Jason.encode!(%{
      tag_name: "v#{version}",
      html_url: "https://github.com/mjason/longx/releases/tag/v#{version}",
      body: "notes",
      draft: false,
      prerelease: false,
      assets:
        for name <- assets do
          %{name: name, browser_download_url: "http://127.0.0.1:#{bypass.port}/dl/#{name}"}
        end
    })
  end

  describe "check/1" do
    test "a newer release is available, with its notes; the result is cached until forced",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/mjason/longx/releases/latest", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        assert ["longx/" <> _] = Plug.Conn.get_req_header(conn, "user-agent")
        Plug.Conn.resp(conn, 200, release_json(bypass, @version, []))
      end)

      assert {:ok,
              %{
                current: current,
                latest: @version,
                tag: "v" <> @version,
                available: true,
                notes_url: "https://github.com/mjason/longx/releases/tag/v" <> @version,
                checked_at: %DateTime{}
              }} = Upgrade.check()

      assert current == Upgrade.current_version()
      # cached: Bypass would fail a second request
      assert {:ok, %{latest: @version}} = Upgrade.check()
    end

    test "the running version is the latest → nothing available", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/mjason/longx/releases/latest", fn conn ->
        Plug.Conn.resp(conn, 200, release_json(bypass, Upgrade.current_version(), []))
      end)

      assert {:ok, %{available: false}} = Upgrade.check(force: true)
    end

    test "a saved GitHub token goes out as the bearer; rate limiting is explained", %{
      bypass: bypass
    } do
      assert :ok = Upgrade.set_github_token("ghp_secret")
      assert Upgrade.github_token?()

      Bypass.expect_once(bypass, "GET", "/repos/mjason/longx/releases/latest", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ghp_secret"]
        Plug.Conn.resp(conn, 200, release_json(bypass, @version, []))
      end)

      assert {:ok, %{available: true}} = Upgrade.check(force: true)

      assert :ok = Upgrade.set_github_token(nil)
      refute Upgrade.github_token?()

      Bypass.expect_once(bypass, "GET", "/repos/mjason/longx/releases/latest", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.resp(403, ~s({"message":"API rate limit exceeded"}))
      end)

      assert {:error, message} = Upgrade.check(force: true)
      assert message =~ "token"
      # the failure is what status reports, the last good result is gone
      assert %{check: nil, error: ^message} = Upgrade.status()
    end

    test "no release yet / GitHub unreachable are errors, never raises", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/repos/mjason/longx/releases/latest", fn conn ->
        Plug.Conn.resp(conn, 404, ~s({"message":"Not Found"}))
      end)

      assert {:error, message} = Upgrade.check(force: true)
      assert message =~ "没有"

      Bypass.down(bypass)
      assert {:error, message} = Upgrade.check(force: true)
      assert message =~ "GitHub"
    end
  end

  describe "apply/0" do
    test "downloads, verifies, backs the database up, swaps the app directory and restarts",
         %{bypass: bypass, root: root, app: app, marker: marker} do
      {name, path, sha} = tarball!(root, @version)

      Bypass.expect(bypass, "GET", "/repos/mjason/longx/releases/latest", fn conn ->
        Plug.Conn.resp(conn, 200, release_json(bypass, @version, [name, name <> ".sha256"]))
      end)

      Bypass.expect_once(bypass, "GET", "/dl/#{name}", fn conn ->
        Plug.Conn.send_file(conn, 200, path)
      end)

      Bypass.expect_once(bypass, "GET", "/dl/#{name}.sha256", fn conn ->
        Plug.Conn.resp(conn, 200, sha)
      end)

      assert {:ok, %{stage: :downloading, target: @version}} = Upgrade.apply()
      # a second click while one runs is refused
      assert {:error, message} = Upgrade.apply()
      assert message =~ "正在"

      assert_receive {:upgrade, %{stage: :restarting}}, 10_000

      assert File.read!(Path.join(app, "bin/longx")) =~ "longx " <> @version
      assert File.read!(Path.join(root, "app.old/bin/longx")) =~ "longx 0.0.1"
      refute File.exists?(Path.join(root, "app.new"))
      assert [backup] = Path.wildcard(Path.join(root, "backups/*.db"))
      assert String.starts_with?(Path.basename(backup), "longx-#{Upgrade.current_version()}-")
      # the snapshot is a real database
      {:ok, db} = Exqlite.Sqlite3.open(backup, mode: :readonly)
      {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "select count(*) from schema_migrations")
      assert {:row, [n]} = Exqlite.Sqlite3.step(db, stmt)
      assert n > 0
      # the download is kept for a manual retry, the restart command ran
      assert File.exists?(Path.join(root, "downloads/#{name}"))
      assert File.read!(marker) =~ "yes"
      assert %{stage: :restarting, target: @version} = Upgrade.status()
    end

    test "a checksum mismatch stops before anything is touched", %{
      bypass: bypass,
      root: root,
      app: app,
      marker: marker
    } do
      {name, path, _sha} = tarball!(root, @version)

      Bypass.expect(bypass, "GET", "/repos/mjason/longx/releases/latest", fn conn ->
        Plug.Conn.resp(conn, 200, release_json(bypass, @version, [name, name <> ".sha256"]))
      end)

      Bypass.expect_once(bypass, "GET", "/dl/#{name}", fn conn ->
        Plug.Conn.send_file(conn, 200, path)
      end)

      Bypass.expect_once(bypass, "GET", "/dl/#{name}.sha256", fn conn ->
        Plug.Conn.resp(conn, 200, String.duplicate("0", 64) <> "  #{name}\n")
      end)

      assert {:ok, _} = Upgrade.apply()
      assert_receive {:upgrade, %{stage: :failed, message: message}}, 10_000
      assert message =~ "sha256"
      assert File.read!(Path.join(app, "bin/longx")) =~ "longx 0.0.1"
      refute File.exists?(Path.join(root, "app.old"))
      refute File.exists?(Path.join(root, "downloads/#{name}"))
      refute File.exists?(marker)
      # and one can try again
      assert %{stage: :failed} = Upgrade.status()
    end

    test "refused when nothing newer is out, when the release has no asset for this machine, and outside an install",
         %{bypass: bypass, app: app} do
      Bypass.expect(bypass, "GET", "/repos/mjason/longx/releases/latest", fn conn ->
        Plug.Conn.resp(conn, 200, release_json(bypass, Upgrade.current_version(), []))
      end)

      assert {:error, message} = Upgrade.apply()
      assert message =~ "最新"

      Bypass.expect(bypass, "GET", "/repos/mjason/longx/releases/latest", fn conn ->
        Plug.Conn.resp(conn, 200, release_json(bypass, @version, ["longx-9.9.9-windows.zip"]))
      end)

      assert {:error, message} = Upgrade.apply()
      assert message =~ "linux-#{Upgrade.arch()}"

      Application.put_env(
        :longx,
        Upgrade,
        Keyword.put(Application.get_env(:longx, Upgrade), :app_dir, nil)
      )

      refute Upgrade.installed?()
      assert {:error, message} = Upgrade.apply()
      assert message =~ "安装"
      assert File.read!(Path.join(app, "bin/longx")) =~ "longx 0.0.1"
    end

    test "without a way to restart the swap still happens and the status says so", %{
      bypass: bypass,
      root: root,
      app: app
    } do
      {name, path, sha} = tarball!(root, @version)

      Application.put_env(
        :longx,
        Upgrade,
        Keyword.put(Application.get_env(:longx, Upgrade), :restart_command, [
          "sh",
          "-c",
          "echo no systemd here >&2; exit 1"
        ])
      )

      Bypass.expect(bypass, "GET", "/repos/mjason/longx/releases/latest", fn conn ->
        Plug.Conn.resp(conn, 200, release_json(bypass, @version, [name, name <> ".sha256"]))
      end)

      Bypass.expect_once(bypass, "GET", "/dl/#{name}", fn conn ->
        Plug.Conn.send_file(conn, 200, path)
      end)

      Bypass.expect_once(bypass, "GET", "/dl/#{name}.sha256", fn conn ->
        Plug.Conn.resp(conn, 200, sha)
      end)

      assert {:ok, _} = Upgrade.apply()
      assert_receive {:upgrade, %{stage: :installed, message: message}}, 10_000
      assert message =~ "重启"
      assert message =~ "no systemd here"
      assert File.read!(Path.join(app, "bin/longx")) =~ "longx " <> @version
    end
  end

  test "install/0 comes from RELEASE_ROOT when not configured", %{app: app} do
    Application.put_env(
      :longx,
      Upgrade,
      Keyword.delete(Application.get_env(:longx, Upgrade), :app_dir)
    )

    assert Upgrade.install(%{}) == nil
    assert Upgrade.install(%{"RELEASE_ROOT" => "/nowhere"}) == nil

    assert %{app: ^app, home: home, service: "longx"} = Upgrade.install(%{"RELEASE_ROOT" => app})
    assert home == Path.dirname(app)

    assert %{service: "longx-dev"} =
             Upgrade.install(%{"RELEASE_ROOT" => app, "LONGX_SERVICE" => "longx-dev"})
  end
end
