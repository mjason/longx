defmodule Longx.Shim.ResourceReport do
  @moduledoc false

  def warning(%{"status" => "unavailable", "reason" => reason}),
    do:
      "WARNING: Linux task cgroup unavailable: #{reason}. Using process-group cleanup and existing memory-pressure guards."

  def warning(_), do: nil

  def exit_reason(nil), do: nil

  def exit_reason(exit) do
    reasons = [
      if(exit["cleanup_error"] not in [nil, ""],
        do: "task cgroup cleanup failed: #{exit["cleanup_error"]}"
      ),
      if(exit["populated"] == true,
        do:
          "task cgroup still populated after cleanup; do not restart the workload until cleanup is verified"
      ),
      if(is_integer(exit["oom_kill"]) and exit["oom_kill"] > 0,
        do:
          "killed by Linux task cgroup: memory limit exceeded (oom_kill increased by #{exit["oom_kill"]}); run a smaller task"
      )
    ]

    case Enum.reject(reasons, &is_nil/1) do
      [] -> nil
      reasons -> Enum.join(reasons, "; ")
    end
  end

  def combine(nil, nil), do: nil
  def combine(reason, nil), do: reason
  def combine(nil, resource), do: resource
  def combine(reason, resource), do: reason <> "; " <> resource

  def job_end(ending, warning, resource) do
    resource_reason = exit_reason(resource)

    {status, reason, observed} =
      case ending do
        {status, reason, observed} ->
          {status, reason, observed}

        nil ->
          status =
            cond do
              resource_reason == nil -> "exited"
              resource["oom_kill"] > 0 -> "killed"
              true -> "failed"
            end

          {status, nil, false}
      end

    # A requested stop or an OOM is not proof that the task tree was cleared.
    # Keep stop attribution/observation, but never label failed cleanup as done.
    status = if cleanup_failed?(resource), do: "failed", else: status

    {status, reason |> combine(warning) |> combine(resource_reason), observed}
  end

  defp cleanup_failed?(nil), do: false

  defp cleanup_failed?(resource),
    do: resource["populated"] == true or resource["cleanup_error"] not in [nil, ""]
end
