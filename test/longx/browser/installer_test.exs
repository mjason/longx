defmodule Longx.Browser.InstallerTest do
  @moduledoc """
  The headless browser is not bundled: the first need downloads it into the
  data directory with progress, one download at a time; the agent's
  `web_fetch` meanwhile answers "being downloaded", never a crash.
  """
  use ExUnit.Case, async: false

  alias Longx.Browser
  alias Longx.Browser.{Installer, Runtime}

  setup do
    root = Path.join(System.tmp_dir!(), "longx-installer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    archive = Path.join(root, "obscura-x86_64-linux.tar.gz")
    build_fake_tarball(archive)
    bypass = Bypass.open()
    previous = Application.get_env(:longx, Longx.Browser, [])

    Application.put_env(
      :longx,
      Longx.Browser,
      previous
      |> Keyword.delete(:executable)
      |> Keyword.merge(
        dir: Path.join(root, "obscura"),
        download_url: "http://localhost:#{bypass.port}/obscura-x86_64-linux.tar.gz",
        download_sha256: sha(archive)
      )
    )

    Installer.reset()

    on_exit(fn ->
      Installer.reset()
      Application.put_env(:longx, Longx.Browser, previous)
      File.rm_rf!(root)
    end)

    :ok = Phoenix.PubSub.subscribe(Longx.PubSub, Installer.topic())
    %{bypass: bypass, archive: archive, root: root}
  end

  # the archive in two chunks with a pause between: a real download arrives in
  # thousands, and the bar must move before the end (it sat at 0 B for a whole
  # 80 MB download once — the throttle compared the monotonic clock against 0)
  defp serve!(bypass, archive) do
    bytes = File.read!(archive)
    half = div(byte_size(bytes), 2)
    <<first::binary-size(half), rest::binary>> = bytes

    Bypass.expect_once(bypass, "GET", "/obscura-x86_64-linux.tar.gz", fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_header("content-length", Integer.to_string(byte_size(bytes)))
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} = Plug.Conn.chunk(conn, first)
      Process.sleep(250)
      {:ok, conn} = Plug.Conn.chunk(conn, rest)
      conn
    end)
  end

  test "nothing installed: the status says so and the executable is not there" do
    assert %{
             stage: :idle,
             version: "0.2.2",
             path: nil,
             target: "x86_64-linux",
             source: nil,
             installed_version: nil,
             latest: "0.2.2",
             upgradable: false
           } = Installer.status()

    assert {:error, :not_installed} = Runtime.executable()
    refute Browser.available?()
  end

  test "install/0 downloads with progress, verifies, extracts into <dir>/<version>/<target>; a second call joins",
       %{bypass: bypass, archive: archive, root: root} do
    serve!(bypass, archive)
    assert :ok = Installer.install()
    # joining while it runs is not a second download (Bypass expects exactly one)
    assert :ok = Installer.install()

    assert_receive {:browser_install, %{stage: :downloading}}, 5_000
    # a progress report from the middle of the download, not only the last one
    assert_receive {:browser_install, %{stage: :downloading, received: mid, total: total_mid}},
                   5_000

    assert is_integer(total_mid) and mid > 0 and mid < total_mid
    assert_receive {:browser_install, %{stage: :installed, path: path}}, 10_000
    assert path == Path.join([root, "obscura", "0.2.2", "x86_64-linux", "obscura"])
    assert File.regular?(path)

    assert %{stage: :installed, path: ^path, received: received, total: total} =
             Installer.status()

    assert received == total and total == byte_size(File.read!(archive))
    assert {:ok, ^path} = Runtime.executable()
    assert Browser.available?()
    # the stages seen in order, the download counted in bytes
    stages = collect_stages([])
    assert :verifying in stages and :extracting in stages
  end

  test "an obscura on PATH changes nothing: the status is idle until our own download is there",
       %{root: root} do
    bin = Path.join(root, "bin")
    system = Path.join(bin, "obscura")
    File.mkdir_p!(bin)
    File.cp!(Path.expand("../../support/fake_obscura.sh", __DIR__), system)
    File.chmod!(system, 0o755)
    previous = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> (previous || ""))

    on_exit(fn ->
      if previous, do: System.put_env("PATH", previous), else: System.delete_env("PATH")
    end)

    Application.put_env(
      :longx,
      Longx.Browser,
      Keyword.put(Application.get_env(:longx, Longx.Browser), :system_path, bin)
    )

    assert %{stage: :idle, source: nil, path: nil, upgradable: false, latest: "0.2.2"} =
             Installer.status()

    refute Browser.available?()
  end

  test "an older download is upgradable: install/0 brings the pinned version and removes the old one",
       %{bypass: bypass, archive: archive, root: root} do
    old = Path.join([root, "obscura", "0.2.1", "x86_64-linux", "obscura"])
    File.mkdir_p!(Path.dirname(old))
    File.write!(old, "#!/bin/sh\necho obscura 0.2.1\n")
    File.chmod!(old, 0o755)

    assert %{
             stage: :installed,
             source: :downloaded,
             path: ^old,
             installed_version: "0.2.1",
             latest: "0.2.2",
             upgradable: true
           } = Installer.status()

    assert {:ok, ^old} = Runtime.executable()

    serve!(bypass, archive)
    assert :ok = Installer.install()
    assert_receive {:browser_install, %{stage: :installed, path: path}}, 10_000
    assert path == Path.join([root, "obscura", "0.2.2", "x86_64-linux", "obscura"])

    assert %{source: :downloaded, installed_version: "0.2.2", upgradable: false} =
             Installer.status()

    refute File.exists?(Path.join([root, "obscura", "0.2.1"]))
  end

  test "a failed download leaves nothing behind and says why", %{bypass: bypass, root: root} do
    Bypass.expect_once(bypass, "GET", "/obscura-x86_64-linux.tar.gz", fn conn ->
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    assert :ok = Installer.install()
    assert_receive {:browser_install, %{stage: :failed, error: error}}, 10_000
    assert error =~ "500"
    refute File.exists?(Path.join([root, "obscura", "0.2.2"]))
    assert %{stage: :failed} = Installer.status()
    # a retry starts over
    Installer.reset()
    assert %{stage: :idle} = Installer.status()
  end

  test "the agent's web_fetch with no browser triggers the download and answers with the progress, never a crash",
       %{bypass: bypass, archive: archive} do
    serve!(bypass, archive)

    assert {:error, {:installing, %{stage: stage}}} = Browser.fetch("https://example.com/")
    assert stage in [:downloading, :verifying, :extracting, :installed]

    assert {:error, message} =
             Longx.Agent.Plugs.Browser.web_fetch(
               %{"url" => "https://example.com/"},
               %Longx.Agent.Context{}
             )

    assert message =~ "being downloaded" or message =~ "installed"
    assert_receive {:browser_install, %{stage: :installed}}, 10_000
  end

  defp collect_stages(acc) do
    receive do
      {:browser_install, %{stage: stage}} -> collect_stages([stage | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp sha(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp build_fake_tarball(path) do
    staging = Path.join(Path.dirname(path), "staging-#{System.unique_integer([:positive])}")

    files = [
      {"obscura-worker", "#!/bin/sh\n", 0o755},
      {"obscura", "#!/bin/sh\necho obscura 0.2.2\n", 0o755}
    ]

    for {name, content, mode} <- files do
      full = Path.join(staging, name)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
      File.chmod!(full, mode)
    end

    entries =
      for {name, _, _} <- files,
          do: {String.to_charlist(name), String.to_charlist(Path.join(staging, name))}

    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    File.rm_rf!(staging)
  end
end
