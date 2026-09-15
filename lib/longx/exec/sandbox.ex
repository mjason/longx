defmodule Longx.Exec.Sandbox do
  @moduledoc """
  Turns a `Longx.Exec.Policy` into the command that enforces it: bubblewrap
  on Linux, seatbelt (`sandbox-exec`) on macOS — the same mechanisms codex's
  own executor uses, with the same filesystem shape (`/` read-only, the
  writable roots bound, the `.git` / `.codex` pockets inside them read-only,
  every namespace unshared, all capabilities dropped) and two deliberate
  differences:

    * **Devices and sockets the project lets in** (`passthrough:` — the GPU
      switch, USB, a daemon's socket) are bound into the minimal `/dev`;
      codex has no way to say that.
    * **No seccomp stage.** codex's inner stage denies `connect` for every
      socket family when the network is off, which kills local IPC too
      (CUDA's driver socket, `nvidia-smi` on a DGX). Here "no network" is
      the network namespace alone: nothing reaches the outside, a unix
      socket in the filesystem still works.

  A policy that needs no sandbox (full access, network on) runs the command
  as it is. A sandbox that cannot be built (no bubblewrap, an unsupported
  platform) is an error — a command is never run open by accident.
  """

  alias Longx.Exec.Policy

  @type kind :: :none | :bwrap | :seatbelt

  @typedoc """
  `platform:` (default the current one), `bwrap:` the bubblewrap to run
  (default `Longx.Codex.Sandbox.bwrap_for_codex/0`), `passthrough:` host
  paths to bind in, `proc:` whether `/proc` can be mounted (default true),
  `exists?:` how to check a path (tests).
  """
  @type opt ::
          {:platform, Longx.Platform.t()}
          | {:bwrap, Path.t() | nil}
          | {:passthrough, [Path.t()]}
          | {:proc, boolean}
          | {:exists?, (Path.t() -> boolean)}

  @doc "The command to run for `argv` under `policy`, tagged with the sandbox kind."
  @spec wrap(Policy.t(), [String.t(), ...], [opt]) ::
          {:ok, {kind, [String.t(), ...]}} | {:error, :no_bwrap | :unsupported}
  def wrap(%Policy{} = policy, argv, opts \\ []) do
    if Policy.sandboxed?(policy) or policy.network == :restricted do
      case Keyword.get_lazy(opts, :platform, &Longx.Platform.current/0) do
        {:linux, _} -> bwrap(policy, argv, opts)
        {:darwin, _} -> {:ok, {:seatbelt, seatbelt(policy, argv)}}
        _ -> {:error, :unsupported}
      end
    else
      {:ok, {:none, argv}}
    end
  end

  @doc "The sandbox kind's name on the exec-server wire (`ProcessSandboxType`)."
  @spec wire_name(kind) :: String.t()
  def wire_name(:none), do: "none"
  def wire_name(:bwrap), do: "linuxSeccomp"
  def wire_name(:seatbelt), do: "macosSeatbelt"

  ## Linux

  defp bwrap(policy, argv, opts) do
    case Keyword.get_lazy(opts, :bwrap, &default_bwrap/0) do
      nil ->
        {:error, :no_bwrap}

      bwrap ->
        exists? = Keyword.get(opts, :exists?, &File.exists?/1)

        args =
          ["--new-session", "--die-with-parent"] ++
            filesystem(policy, exists?) ++
            ["--dev", "/dev"] ++
            passthrough(Keyword.get(opts, :passthrough, []), exists?) ++
            writable(policy, exists?) ++
            ["--unshare-user", "--unshare-pid", "--unshare-ipc"] ++
            if(policy.network == :restricted, do: ["--unshare-net"], else: []) ++
            if(Keyword.get(opts, :proc, true), do: ["--proc", "/proc"], else: []) ++
            ["--cap-drop", "ALL", "--"] ++ argv

        {:ok, {:bwrap, [bwrap | args]}}
    end
  end

  defp default_bwrap do
    case Longx.Codex.Sandbox.bwrap_for_codex() do
      {which, path} when which in [:system, :bundled] -> path
      {:error, _} -> nil
    end
  end

  # the whole filesystem, writable only when the policy needs no sandbox
  # (it is here for its network namespace alone)
  defp filesystem(policy, _exists?) do
    if Policy.sandboxed?(policy), do: ["--ro-bind", "/", "/"], else: ["--bind", "/", "/"]
  end

  # devices under /dev need --dev-bind (character/block nodes), the rest a plain bind
  defp passthrough(paths, exists?) do
    paths
    |> Enum.filter(exists?)
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      flag = if String.starts_with?(path, "/dev/"), do: "--dev-bind", else: "--bind"
      [flag, path, path]
    end)
  end

  # writable roots shallowest first (a deeper one mounts over a shallower),
  # each followed by its read-only pockets; only what exists can be bound
  defp writable(policy, exists?) do
    if Policy.sandboxed?(policy) do
      pockets = Policy.read_only_paths(policy)

      policy
      |> Policy.writable_roots()
      |> Enum.filter(exists?)
      |> Enum.sort_by(&depth/1)
      |> Enum.flat_map(fn root ->
        (["--bind", root, root] ++
           for(
             pocket <- pockets,
             Policy.under?(pocket, root),
             exists?.(pocket),
             do: ["--ro-bind", pocket, pocket]
           ))
        |> List.flatten()
      end)
    else
      []
    end
  end

  defp depth(path), do: path |> Path.split() |> length()

  ## macOS

  @seatbelt_exe "/usr/bin/sandbox-exec"
  @sbpl_dir Path.join(:code.priv_dir(:longx), "seatbelt")
  @external_resource Path.join(@sbpl_dir, "seatbelt_base_policy.sbpl")
  @external_resource Path.join(@sbpl_dir, "seatbelt_network_policy.sbpl")
  @external_resource Path.join(@sbpl_dir, "seatbelt_preferences_policy.sbpl")
  @base_policy File.read!(Path.join(@sbpl_dir, "seatbelt_base_policy.sbpl"))
  @network_policy File.read!(Path.join(@sbpl_dir, "seatbelt_network_policy.sbpl"))
  @preferences_policy File.read!(Path.join(@sbpl_dir, "seatbelt_preferences_policy.sbpl"))

  # codex's profile (sandboxing/src/seatbelt.rs, its .sbpl files vendored in
  # priv/seatbelt): the base policy, reads everywhere, writes on the roots
  # minus their pockets, the network section when the network is on
  defp seatbelt(policy, argv) do
    {write_policy, params} = seatbelt_writes(policy)

    profile =
      [
        @base_policy,
        "; allow read-only file operations\n(allow file-read*)",
        write_policy,
        if(policy.network == :enabled,
          do: "(allow network-outbound)\n(allow network-inbound)\n" <> @network_policy,
          else: ""
        ),
        @preferences_policy
      ]
      |> Enum.join("\n")

    [@seatbelt_exe, "-p", profile] ++
      for({key, value} <- params, do: "-D#{key}=#{value}") ++ ["--"] ++ argv
  end

  defp seatbelt_writes(policy) do
    if Policy.sandboxed?(policy) do
      pockets = Policy.read_only_paths(policy)

      {components, params} =
        policy
        |> Policy.writable_roots()
        |> Enum.with_index()
        |> Enum.map(fn {root, i} ->
          key = "WRITABLE_ROOT_#{i}"
          excluded = pockets |> Enum.filter(&Policy.under?(&1, root)) |> Enum.with_index()

          parts =
            [~s[(subpath (param "#{key}"))]] ++
              Enum.flat_map(excluded, fn {_, j} ->
                [
                  ~s[(require-not (literal (param "#{key}_EXCLUDED_#{j}")))],
                  ~s[(require-not (subpath (param "#{key}_EXCLUDED_#{j}")))]
                ]
              end)

          component =
            if excluded == [], do: hd(parts), else: "(require-all #{Enum.join(parts, " ")} )"

          {component,
           [{key, root} | for({pocket, j} <- excluded, do: {"#{key}_EXCLUDED_#{j}", pocket})]}
        end)
        |> Enum.unzip()

      case components do
        [] ->
          {"", []}

        _ ->
          denies =
            for {key, _} <- List.flatten(params),
                not String.contains?(key, "EXCLUDED"),
                do:
                  ~s[(deny file-write-unlink (require-all (literal (param "#{key}")) (vnode-type DIRECTORY)))]

          {Enum.join(["(allow file-write*\n#{Enum.join(components, " ")}\n)" | denies], "\n"),
           List.flatten(params)}
      end
    else
      {~s[(allow file-write* (regex #"^/"))], []}
    end
  end
end
