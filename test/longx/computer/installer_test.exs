defmodule Longx.Computer.InstallerTest do
  use ExUnit.Case, async: false

  alias Longx.Computer.{Installer, Runtime}

  setup do
    root = Path.join(System.tmp_dir!(), "longx-computer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:longx, Longx.Computer, [])
    override = System.get_env("LONGX_CUA_DRIVER")
    System.delete_env("LONGX_CUA_DRIVER")
    Application.put_env(:longx, Longx.Computer, dir: Path.join(root, "driver"))
    Installer.reset()
    Phoenix.PubSub.subscribe(Longx.PubSub, Installer.topic())

    on_exit(fn ->
      Installer.reset()
      Application.put_env(:longx, Longx.Computer, previous)

      if override,
        do: System.put_env("LONGX_CUA_DRIVER", override),
        else: System.delete_env("LONGX_CUA_DRIVER")

      File.rm_rf!(root)
    end)

    %{root: root, target: Runtime.current_target()}
  end

  test "platform mapping covers all six release targets and rejects unknown platforms" do
    for {platform, target} <- [
          {{:darwin, :aarch64}, "darwin-arm64"},
          {{:darwin, :x86_64}, "darwin-x86_64"},
          {{:linux, :aarch64}, "linux-arm64"},
          {{:linux, :x86_64}, "linux-x86_64"},
          {{:windows, :aarch64}, "windows-arm64"},
          {{:windows, :x86_64}, "windows-x86_64"}
        ] do
      assert Runtime.target(platform) == target
      assert byte_size(Runtime.sha256(target)) == 64
      assert Runtime.download_size(target) > 0

      assert String.ends_with?(
               Runtime.asset_name(target),
               if(elem(platform, 0) == :windows, do: ".zip", else: ".tar.gz")
             )
    end

    assert Runtime.target({:freebsd, :x86_64}) == nil
  end

  test "empty status distinguishes the download from an active desktop connection" do
    assert %{stage: :idle, path: nil, app_path: nil, source: nil, upgradable: false} =
             Installer.status()

    assert {:error, :not_installed} = Runtime.resolve()
  end

  test "the layout installer accepts complete tar and zip releases for every target",
       %{root: root} do
    for target <-
          ~w(darwin-arm64 darwin-x86_64 linux-arm64 linux-x86_64 windows-arm64 windows-x86_64) do
      archive = archive(root, target)

      assert {:ok, path} =
               Runtime.install(target,
                 dir: Path.join(root, "all-platforms"),
                 source: {:file, archive},
                 sha256: sha(archive)
               )

      assert File.regular?(path)
    end
  end

  test "an older complete download stays usable and settings offers an upgrade",
       %{target: target} do
    version = "0.31.0"
    path = Runtime.executable_path(Path.join([Runtime.dir(), version, target]), target, version)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not executed")

    if app = Runtime.app_path(path, target) do
      exe = Path.join(app, "Contents/MacOS/cua-driver")
      File.mkdir_p!(Path.dirname(exe))
      File.write!(exe, "not executed")
    end

    assert %{stage: :installed, installed_version: ^version, path: ^path, upgradable: true} =
             Installer.status()
  end

  test "downloads once, verifies the complete package and exposes the installed path",
       %{root: root, target: target} do
    archive = archive(root, target)
    bypass = serve(archive)
    configure(bypass, archive)

    assert :ok = Installer.install()
    assert :ok = Installer.install()
    assert_receive {:computer_install, %{stage: :downloading}}, 5_000
    assert_receive {:computer_install, %{stage: :installed, path: path}}, 10_000
    assert File.regular?(path)
    assert Runtime.installed?(target)
    assert {:ok, :downloaded, ^path, "0.32.0"} = Runtime.resolve()

    st = Installer.status()
    assert st.received == st.total
    assert st.installed_version == st.latest
    if String.starts_with?(target, "darwin-"), do: assert(File.dir?(st.app_path))
  end

  test "a checksum failure installs nothing and can be retried", %{root: root, target: target} do
    archive = archive(root, target)
    bypass = serve(archive)
    configure(bypass, archive, String.duplicate("0", 64))
    assert :ok = Installer.install()
    assert_receive {:computer_install, %{stage: :failed, error: error}}, 10_000
    assert error =~ "checksum"
    assert {:error, :not_installed} = Runtime.resolve()

    bypass = serve(archive)
    configure(bypass, archive)
    assert :ok = Installer.install()
    assert_receive {:computer_install, %{stage: :installed}}, 10_000
  end

  test "macOS package must include the permission-owning app", %{root: root} do
    target = "darwin-arm64"
    archive = archive(root, target, app: false)

    assert {:error, {:extract_failed, :missing_driver_or_app}} =
             Runtime.install(target,
               dir: Path.join(root, "driver"),
               source: {:file, archive},
               sha256: sha(archive)
             )
  end

  test "an explicit existing binary is adopted without a download", %{root: root} do
    binary = Path.join(root, "custom-driver")
    File.write!(binary, "not executed by status")
    System.put_env("LONGX_CUA_DRIVER", binary)

    assert %{stage: :installed, source: :env, path: ^binary, upgradable: false} =
             Installer.status()

    assert :ok = Installer.install()
    refute File.dir?(Runtime.dir())
    System.put_env("LONGX_CUA_DRIVER", Path.join(root, "missing"))
    assert {:error, :not_installed} = Runtime.resolve()
  end

  defp configure(bypass, archive, checksum \\ nil) do
    Application.put_env(
      :longx,
      Longx.Computer,
      Application.get_env(:longx, Longx.Computer)
      |> Keyword.merge(
        download_url: "http://localhost:#{bypass.port}/driver",
        download_sha256: checksum || sha(archive)
      )
    )
  end

  defp serve(archive) do
    bypass = Bypass.open()
    bytes = File.read!(archive)

    Bypass.expect_once(bypass, "GET", "/driver", fn conn ->
      Plug.Conn.send_resp(conn, 200, bytes)
    end)

    bypass
  end

  defp archive(root, target, opts \\ []) do
    package = Runtime.package_name(target)
    binary = Path.relative_to(Runtime.executable_path(root, target), root)
    entries = [{binary, "#!/bin/sh\n"}]

    entries =
      if String.starts_with?(target, "darwin-") and Keyword.get(opts, :app, true),
        do:
          entries ++
            [{Path.join([package, "CuaDriver.app/Contents/MacOS/cua-driver"]), "#!/bin/sh\n"}],
        else: entries

    path = Path.join(root, Runtime.asset_name(target))

    if String.ends_with?(path, ".zip") do
      files = Enum.map(entries, fn {name, bytes} -> {String.to_charlist(name), bytes} end)
      {:ok, _} = :zip.create(String.to_charlist(path), files)
    else
      files =
        for {name, bytes} <- entries do
          full = Path.join(root, name)
          File.mkdir_p!(Path.dirname(full))
          File.write!(full, bytes)
          File.chmod!(full, 0o755)
          {String.to_charlist(name), String.to_charlist(full)}
        end

      :ok = :erl_tar.create(String.to_charlist(path), files, [:compressed])
    end

    path
  end

  defp sha(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
