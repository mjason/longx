defmodule Longx.System.CommandGuard do
  @moduledoc """
  A read-only capability preflight, kept separate from actual task containment.
  An eligible host still needs a successful task-start resource-guard report.
  """

  alias Longx.Shim

  def report(settings, opts \\ []) do
    mode = Map.get(settings, :command_cgroup_mode, "auto")
    platform = Keyword.get(opts, :platform, Longx.Platform.current())
    probe = Keyword.get(opts, :probe, &probe/0)
    reports = Keyword.get(opts, :reports, &Shim.Resources.snapshots/0).()

    capability =
      cond do
        mode == "off" ->
          %{status: "off", reason: nil, path: nil}

        not match?({:linux, _}, platform) ->
          %{status: "unsupported", reason: "Task cgroup protection is Linux-only.", path: nil}

        true ->
          capability(probe.())
      end

    latest = Enum.max_by(reports, & &1.sequence, fn -> nil end)
    guard = (latest && latest.guard) || %{}
    exit = (latest && latest.exit) || %{}

    %{
      mode: mode,
      platform: platform |> elem(0) |> Atom.to_string(),
      capability: capability.status,
      reason: capability.reason,
      path: capability.path,
      active_tasks:
        Enum.count(
          reports,
          &(&1.live and is_map(&1.guard) and &1.guard["status"] == "active" and is_nil(&1.exit))
        ),
      cleanup_pending_tasks: Enum.count(reports, &cleanup_pending?(&1.exit)),
      last_task_status: guard["status"],
      last_task_reason: guard["reason"],
      last_task_path: guard["path"],
      last_oom_kill: exit["oom_kill"],
      last_populated: exit["populated"],
      last_cleanup_error: exit["cleanup_error"],
      last_observed_at: latest && Map.get(latest, :observed_at),
      checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  def start_check(mode, platform \\ Longx.Platform.current()) do
    if mode in ["required", :required] and not match?({:linux, _}, platform),
      do: {:error, "Task cgroup protection is Linux-only; required mode refuses this task."},
      else: :ok
  end

  def unsupported_warning(mode, platform \\ Longx.Platform.current()) do
    if mode in ["auto", :auto] and not match?({:linux, _}, platform),
      do:
        Shim.ResourceReport.warning(%{
          "status" => "unavailable",
          "reason" => "task cgroup protection is Linux-only"
        })
  end

  defp cleanup_pending?(nil), do: false

  defp cleanup_pending?(exit),
    do: exit["populated"] == true or exit["cleanup_error"] not in [nil, ""]

  defp capability({:ok, %{"status" => status} = report})
       when status in ["eligible", "unavailable"] do
    if is_binary(Map.get(report, "reason", "")) and is_binary(Map.get(report, "path", "")) do
      %{
        status: status,
        reason:
          report["reason"] ||
            if(status == "unavailable", do: "Cgroup delegation prerequisites are unavailable."),
        path: report["path"]
      }
    else
      capability({:error, :invalid_report})
    end
  end

  defp capability(error),
    do: %{
      status: "unavailable",
      reason: "Cgroup preflight could not verify support: #{inspect(error)}",
      path: nil
    }

  defp probe do
    # Only the native read-only helper; no shell, cgroup/task setup, or ledger entry.
    case Shim.run([Shim.executable(), "cgroup-status"], cgroup: :off, timeout: 2_000) do
      {:ok, %{status: 0, stdout: text}} -> Jason.decode(text)
      other -> {:error, other}
    end
  catch
    :exit, reason -> {:error, reason}
  end
end
