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
      platform: {:linux, :x86_64},
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
    name = Upgrade.asset_name(version)
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

  describe "platform compatibility" do
    test "default macOS restart invokes launchctl for the current GUI user", %{
      bypass: bypass,
      root: root,
      marker: marker
    } do
      config = Application.get_env(:longx, Upgrade)

      Application.put_env(
        :longx,
        Upgrade,
        config
        |> Keyword.put(:platform, {:darwin, :aarch64})
        |> Keyword.put(:restart_command, nil)
      )

      previous_path = System.get_env("PATH")
      fake_bin = Path.join(root, "fake-bin")
      File.mkdir_p!(fake_bin)
      command = Path.join(fake_bin, "launchctl")
      File.write!(command, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"#{marker}\"\n")
      File.chmod!(command, 0o755)
      System.put_env("PATH", fake_bin <> ":" <> previous_path)
      on_exit(fn -> System.put_env("PATH", previous_path) end)
      {uid, 0} = System.cmd("/usr/bin/id", ["-u"])
      {name, path, sha} = tarball!(root, @version)

      Bypass.expect(bypass, "GET", "/repos/mjason/longx/releases/latest", fn conn ->
        Plug.Conn.resp(conn, 200, release_json(bypass, @version, [name, name <> ".sha256"]))
      end)

      Bypass.expect_once(bypass, "GET", "/dl/#{name}", &Plug.Conn.send_file(&1, 200, path))
      Bypass.expect_once(bypass, "GET", "/dl/#{name}.sha256", &Plug.Conn.resp(&1, 200, sha))
      assert {:ok, _} = Upgrade.apply()
      assert_receive {:upgrade, %{stage: :restarting}}, 10_000

      assert File.read!(marker) |> String.split("\n", trim: true) ==
               ["kickstart", "-k", "gui/#{String.trim(uid)}/com.longx.agent"]
    end

    test "selects the actual release names, including native Apple Silicon" do
      assert Upgrade.arch({:darwin, :aarch64}) == "arm64"

      assert Upgrade.asset_name(@version, {:darwin, :aarch64}) ==
               "longx-9.9.9-darwin-arm64.tar.gz"

      assert Upgrade.asset_name(@version, {:linux, :x86_64}) ==
               "longx-9.9.9-linux-x86_64.tar.gz"

      assert Upgrade.asset_name(@version, {:linux, :aarch64}) ==
               "longx-9.9.9-linux-arm64.tar.gz"

      assert Upgrade.asset_name(@version, {:darwin, :x86_64}) == nil
      assert Upgrade.asset_name(@version, {:windows, :x86_64}) == nil
    end

    test "macOS installations default to the installer LaunchAgent label", %{app: app} do
      config = Application.get_env(:longx, Upgrade)
      Application.put_env(:longx, Upgrade, Keyword.put(config, :platform, {:darwin, :aarch64}))
      assert %{service: "com.longx.agent"} = Upgrade.install(%{"RELEASE_ROOT" => app})

      assert %{service: "com.longx.test"} =
               Upgrade.install(%{"RELEASE_ROOT" => app, "LONGX_SERVICE" => "com.longx.test"})
    end

    test "macOS restart targets the current user's GUI LaunchAgent, not systemd" do
      assert {:ok, ["launchctl", "kickstart", "-k", "gui/501/com.longx.agent"]} =
               Upgrade.restart_command(%{service: "com.longx.agent"}, {:darwin, :aarch64}, "501")

      assert {:ok, ["systemctl", "--user", "restart", "--no-block", "longx"]} =
               Upgrade.restart_command(%{service: "longx"}, {:linux, :x86_64}, nil)

      assert {:error, _} =
               Upgrade.restart_command(%{service: "com.longx.agent"}, {:darwin, :aarch64}, "")
    end

    test "downloads and applies a macOS archive instead of searching for Linux", %{
      bypass: bypass,
      root: root,
      app: app,
      marker: marker
    } do
      config = Application.get_env(:longx, Upgrade)
      Application.put_env(:longx, Upgrade, Keyword.put(config, :platform, {:darwin, :aarch64}))
      {name, path, sha} = tarball!(root, @version)
      assert name == "longx-9.9.9-darwin-arm64.tar.gz"

      Bypass.expect(bypass, "GET", "/repos/mjason/longx/releases/latest", fn conn ->
        Plug.Conn.resp(conn, 200, release_json(bypass, @version, [name, name <> ".sha256"]))
      end)

      Bypass.expect_once(bypass, "GET", "/dl/#{name}", &Plug.Conn.send_file(&1, 200, path))
      Bypass.expect_once(bypass, "GET", "/dl/#{name}.sha256", &Plug.Conn.resp(&1, 200, sha))
      assert {:ok, _} = Upgrade.apply()
      assert_receive {:upgrade, %{stage: :restarting}}, 10_000
      assert File.read!(Path.join(app, "bin/longx")) =~ @version
      assert File.read!(Path.join(root, "app.old/bin/longx")) =~ "0.0.1"
      assert File.read!(marker) =~ "yes"
    end
  end

  # config.exs once set the upgrade's clock after importing test.exs, so the
  # suite ran a 6 h tick: a real GitHub check a minute after boot, and a
  # crash (send_after(nil)) whenever it landed inside a test of this module
  test "the suite's config keeps the periodic check off: an env file's word stands" do
    config = Config.Reader.read!("config/config.exs", env: :test, target: :host)
    assert get_in(config, [:longx, Upgrade, :tick]) == nil
    assert get_in(config, [:longx, Oban, :testing]) == :manual
  end

  describe "apply/0" do
    test "downloads, verifies, backs the database up, swaps the app directory and restarts",
         %{bypass: bypass, root: root, app: app, marker: marker} do
      {name, path, sha} = tarball!(root, @version)

      Bypass.expect(bypass, "GET", "/repos/mjason/longx/releases/latest", fn conn ->
        Plug.Conn.resp(conn, 200, release_json(bypass, @version, [name, name <> ".sha256"]))
      end)

      # the tarball comes in chunks with a content-length: the page shows a bar
      Bypass.expect_once(bypass, "GET", "/dl/#{name}", fn conn ->
        data = File.read!(path)

        conn =
          conn
          |> Plug.Conn.put_resp_header("content-length", Integer.to_string(byte_size(data)))
          |> Plug.Conn.send_chunked(200)

        # a pause between chunks: the bar must move before the end (a throttle that
        # compared the monotonic clock against 0 never reported a byte on Linux)
        for chunk <- chunks(data, 3) do
          {:ok, _} = Plug.Conn.chunk(conn, chunk)
          Process.sleep(250)
        end

        conn
      end)

      Bypass.expect_once(bypass, "GET", "/dl/#{name}.sha256", fn conn ->
        Plug.Conn.resp(conn, 200, sha)
      end)

      assert {:ok, %{stage: :downloading, target: @version, progress: nil}} = Upgrade.apply()
      # a second click while one runs is refused
      assert {:error, message} = Upgrade.apply()
      assert message =~ "正在"

      # progress: bytes received against the total — first from the middle, then complete
      assert_receive {:upgrade, %{stage: :downloading, progress: %{received: r, total: total}}},
                     10_000

      assert is_integer(r) and r > 0 and r < total and total == File.stat!(path).size
      assert_receive {:upgrade, %{stage: :restarting, progress: nil}}, 10_000

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

      release_root = System.get_env("RELEASE_ROOT")
      System.delete_env("RELEASE_ROOT")

      try do
        refute Upgrade.installed?()
        assert {:error, message} = Upgrade.apply()
        assert message =~ "安装"
        assert File.read!(Path.join(app, "bin/longx")) =~ "longx 0.0.1"
      after
        if release_root, do: System.put_env("RELEASE_ROOT", release_root)
      end
    end

    test "inside a container (LONGX_CONTAINER, set by the image) nothing is installable: the upgrade is a new image; the status says so",
         %{app: app} do
      Elixir.System.put_env("LONGX_CONTAINER", "1")
      on_exit(fn -> Elixir.System.delete_env("LONGX_CONTAINER") end)
      # the app dir is there, so only the container flag holds this back
      assert File.regular?(Path.join(app, "bin/longx"))
      refute Upgrade.installed?()
      assert %{installed: false, container: true} = Upgrade.status()
      assert {:error, message} = Upgrade.apply()
      assert message =~ "镜像"
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

  defp chunks(data, n) do
    size = max(div(byte_size(data), n), 1)

    Stream.unfold(data, fn
      "" -> nil
      rest when byte_size(rest) <= size -> {rest, ""}
      rest -> {binary_part(rest, 0, size), binary_part(rest, size, byte_size(rest) - size)}
    end)
    |> Enum.to_list()
  end
end
