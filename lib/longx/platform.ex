defmodule Longx.Platform do
  @moduledoc """
  Runtime-safe detection of the OS/CPU the BEAM is running on, plus the
  naming conventions other toolchains use for it (Rust target triples for
  release assets like obscura's, GOOS/GOARCH for the shim). Usable inside a
  release — no Mix here.
  """

  @type os :: :linux | :darwin | :windows | atom
  @type arch :: :x86_64 | :aarch64 | atom
  @type t :: {os, arch}

  @doc "The current `{os, arch}`."
  @spec current() :: t
  def current do
    detect(
      :os.type(),
      List.to_string(:erlang.system_info(:system_architecture)),
      System.get_env()
    )
  end

  @doc """
  Pure detection from `:os.type/0`, `:erlang.system_info(:system_architecture)`
  and the environment (Windows ERTS only reports `"win32"`, so the CPU comes
  from `PROCESSOR_ARCHITECTURE`).
  """
  @spec detect({:unix | :win32, atom}, String.t(), %{optional(String.t()) => String.t()}) :: t
  def detect(os_type, system_architecture, env \\ %{})

  def detect({:win32, _}, _arch, env) do
    arch =
      case env |> Map.get("PROCESSOR_ARCHITECTURE", "") |> String.downcase() do
        "arm64" -> :aarch64
        _ -> :x86_64
      end

    {:windows, arch}
  end

  def detect({:unix, os}, system_architecture, _env) do
    arch = system_architecture |> String.split("-") |> hd() |> normalize_arch()
    {os, arch}
  end

  defp normalize_arch("amd64"), do: :x86_64
  defp normalize_arch("arm64"), do: :aarch64
  defp normalize_arch(other), do: String.to_atom(other)

  @doc "Rust target triple as used by Rust projects' release asset names."
  @spec rust_target(t) :: String.t()
  def rust_target({:linux, arch}), do: "#{arch}-unknown-linux-musl"
  def rust_target({:darwin, arch}), do: "#{arch}-apple-darwin"
  def rust_target({:windows, arch}), do: "#{arch}-pc-windows-msvc"

  @doc "`{GOOS, GOARCH}` for the shim build."
  @spec go_target(t) :: {String.t(), String.t()}
  def go_target({os, arch}) do
    goos =
      case os do
        :linux -> "linux"
        :darwin -> "darwin"
        :windows -> "windows"
        other -> Atom.to_string(other)
      end

    goarch =
      case arch do
        :x86_64 -> "amd64"
        :aarch64 -> "arm64"
        other -> Atom.to_string(other)
      end

    {goos, goarch}
  end

  @spec exe_suffix(t) :: String.t()
  def exe_suffix({:windows, _}), do: ".exe"
  def exe_suffix(_), do: ""

  @doc "File name of the Go shim binary for `platform`."
  @spec shim_executable_name(t) :: String.t()
  def shim_executable_name(platform \\ current()) do
    {goos, goarch} = go_target(platform)
    "shim_#{goos}_#{goarch}#{exe_suffix(platform)}"
  end
end
