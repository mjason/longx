defmodule Mix.Tasks.Compile.Shim do
  @shortdoc "Builds the Go shim used by Longx.Shim"

  @moduledoc """
  Compiles `native/shim` into `priv/bin/shim_<os>_<arch>` with `go build`.

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
    Path.wildcard("priv/bin/shim_*") |> Enum.each(&File.rm/1)
    :ok
  end

  @doc "File name of the shim binary for `platform` (defaults to the current one)."
  def executable_name({os, arch} \\ current_platform()) do
    ext = if os == "windows", do: ".exe", else: ""
    "shim_#{os}_#{arch}#{ext}"
  end

  defp build(output, {os, arch}) do
    File.mkdir_p!(Path.dirname(output))
    Mix.shell().info("Compiling Go shim (#{os}/#{arch})")

    env = [{"GOOS", os}, {"GOARCH", arch}, {"CGO_ENABLED", "0"}]
    args = ["build", "-trimpath", "-ldflags", "-s -w", "-o", Path.expand(output)]

    case System.cmd("go", args, cd: @source_dir, env: env, stderr_to_stdout: true) do
      {_, 0} -> {:ok, []}
      {out, _} -> error("go build failed:\n\n" <> out)
    end
  end

  defp stale?(output) do
    case File.stat(output, time: :posix) do
      {:error, _} ->
        true

      {:ok, %{mtime: built_at}} ->
        Path.wildcard("#{@source_dir}/**/*.{go,mod,sum}")
        |> Enum.any?(fn src -> File.stat!(src, time: :posix).mtime > built_at end)
    end
  end

  defp output_path(platform), do: Path.join("priv/bin", executable_name(platform))

  defp target_platform do
    case {System.get_env("SHIM_GOOS"), System.get_env("SHIM_GOARCH")} do
      {os, arch} when is_binary(os) and is_binary(arch) -> {os, arch}
      _ -> current_platform()
    end
  end

  @doc "The `{goos, goarch}` pair the running BEAM was built for."
  def current_platform do
    os =
      case :os.type() do
        {:win32, _} -> "windows"
        {:unix, :darwin} -> "darwin"
        {:unix, _} -> "linux"
      end

    arch =
      :erlang.system_info(:system_architecture)
      |> List.to_string()
      |> String.split("-")
      |> hd()
      |> case do
        "x86_64" -> "amd64"
        "amd64" -> "amd64"
        "aarch64" -> "arm64"
        "arm64" -> "arm64"
        "win32" -> windows_arch()
        other -> other
      end

    {os, arch}
  end

  defp windows_arch do
    case System.get_env("PROCESSOR_ARCHITECTURE", "") |> String.downcase() do
      "arm64" -> "arm64"
      _ -> "amd64"
    end
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
