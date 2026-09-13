defmodule Longx.System.Status do
  @moduledoc "A resource without data: generic actions reporting on this node."

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.System,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name "SystemStatus"
  end

  actions do
    # Longx.Codex.Sandbox.report/0 for the UI's banner
    action :sandbox, :map do
      constraints fields: [
                    status: [
                      type: :atom,
                      allow_nil?: false,
                      constraints: [one_of: [:ok, :unavailable]]
                    ],
                    reason: [type: :string],
                    checked_at: [type: :utc_datetime_usec, allow_nil?: false]
                  ]

      run fn _input, _ ->
        report = Longx.Codex.Sandbox.report()

        {:ok,
         %{status: report.status, reason: reason(report.reason), checked_at: report.checked_at}}
      end
    end
  end

  defp reason(nil), do: nil
  defp reason({kind, message}), do: "#{kind}: #{message}"
  defp reason(other), do: to_string(other)
end
