defmodule Mix.Tasks.Compile.Shim do
  @shortdoc "Builds the Go shim used by Longx.Shim"

  @moduledoc """
  Compiles `native/shim` into `priv/bin/shim_<os>_<arch>` with `go build`,
  and, for Linux targets, `native/shim/cmd/bwrapx` into
  `priv/bin/bwrapx_linux_<arch>` — the bubblewrap wrapper
  `Longx.Codex.Home` puts on codex's PATH when a project lets host paths
  into its sandbox.

  Runs as part of `mix compile` (see `:compilers` in `mix.exs`) and only
  rebuilds when a Go source file is newer than the binary. Set `SHIM_GOOS` /
  `SHIM_GOARCH` to cross-compile, e.g. when building a release for another
  platform. Adapted from ex_cmd's `Mix.Tasks.Compile.Odu` (MIT).
  """

  use Mix.Task.Compiler

  @recursive true
  @source_dir "native/shim"

  @impl Mix.Task.Compiler
  def run(_args) do
    platform = target_platform()
    output = output_path(platform)

    cond do
      not stale?(output) ->
        {:noop, []}

      System.find_executable("go") == nil ->
        error("""
        `go` was not found on PATH. The Longx.Shim middleware is built from
        #{@source_dir} at compile time; install Go (https://go.dev/dl/) and re-run
        `mix compile`.
        """)

      true ->
        build(output, platform)
    end
  end

  @impl Mix.Task.Compiler
  def clean do
    Path.wildcard("priv/bin/{shim,bwrapx}_*") |> Enum.each(&File.rm/1)
    :ok
  end

  @doc "File name of the shim binary for the current platform."
  def executable_name, do: Longx.Platform.shim_executable_name()

  defp build(output, {os, arch} = platform) do
    File.mkdir_p!(Path.dirname(output))
    Mix.shell().info("Compiling Go shim (#{os}/#{arch})")

    with {:ok, _} <- go_build(".", output, platform),
         {:ok, _} <- build_bwrapx(platform) do
      {:ok, []}
    end
  end

  # the bwrap wrapper only makes sense where codex sandboxes with bubblewrap
  defp build_bwrapx({"linux", _} = platform),
    do: go_build("./cmd/bwrapx", bwrapx_path(platform), platform)

  defp build_bwrapx(_platform), do: {:ok, []}

  defp go_build(package, output, {os, arch}) do
    env = [{"GOOS", os}, {"GOARCH", arch}, {"CGO_ENABLED", "0"}]
    args = ["build", "-trimpath", "-ldflags", "-s -w", "-o", Path.expand(output), package]

    case System.cmd("go", args, cd: @source_dir, env: env, stderr_to_stdout: true) do
      {_, 0} -> {:ok, []}
      {out, _} -> error("go build #{package} failed:\n\n" <> out)
    end
  end

  defp bwrapx_path({os, arch}), do: Path.join("priv/bin", "bwrapx_#{os}_#{arch}")

  defp stale?(output) do
    case File.stat(output, time: :posix) do
      {:error, _} ->
        true

      {:ok, %{mtime: built_at}} ->
        Path.wildcard("#{@source_dir}/**/*.{go,mod,sum}")
        |> Enum.any?(fn src -> File.stat!(src, time: :posix).mtime > built_at end)
    end
  end

  defp target_platform do
    case {System.get_env("SHIM_GOOS"), System.get_env("SHIM_GOARCH")} do
      {os, arch} when is_binary(os) and is_binary(arch) -> {os, arch}
      _ -> Longx.Platform.go_target(Longx.Platform.current())
    end
  end

  defp output_path({os, arch}) do
    suffix = if os == "windows", do: ".exe", else: ""
    Path.join("priv/bin", "shim_#{os}_#{arch}#{suffix}")
  end

  defp error(message) do
    Mix.shell().error(message)

    {:error,
     [
       %Mix.Task.Compiler.Diagnostic{
         compiler_name: "shim",
         file: Path.expand(@source_dir),
         position: 0,
         severity: :error,
         message: message
       }
     ]}
  end
end
