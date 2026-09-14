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
    # The directory picker: subdirectories of `path` (home when omitted),
    # each flagged when it is a git repository. Files are never listed;
    # dot-directories only with `show_hidden`. Paths must be absolute.
    action :list_directory, :map do
      constraints fields: [
                    path: [type: :string, allow_nil?: false],
                    parent: [type: :string],
                    git: [type: :boolean, allow_nil?: false],
                    # arrays of typed maps are not selectable in ash_typescript 0.18's
                    # field types; the entry shape (name, path, git) is typed client-side
                    entries: [type: {:array, :map}, allow_nil?: false],
                    roots: [type: {:array, :map}, allow_nil?: false]
                  ]

      argument :path, :string
      argument :show_hidden, :boolean, default: false

      run fn input, _ ->
        Longx.System.Directory.list(input.arguments[:path],
          show_hidden: input.arguments.show_hidden
        )
      end
    end

    # The picker's "new directory": one segment under an existing parent;
    # answers the entry as the listing would show it
    action :create_directory, :map do
      constraints fields: [
                    name: [type: :string, allow_nil?: false],
                    path: [type: :string, allow_nil?: false],
                    git: [type: :boolean, allow_nil?: false]
                  ]

      argument :parent, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false

      run fn input, _ ->
        Longx.System.Directory.create(input.arguments.parent, input.arguments.name)
      end
    end

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

      run fn _input, _ -> {:ok, sandbox_report(Longx.Codex.Sandbox.report())} end
    end

    # the same report after running the probe again (the settings page's "重新检测")
    action :probe_sandbox, :map do
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
        Longx.Codex.Sandbox.probe()
        {:ok, sandbox_report(Longx.Codex.Sandbox.report())}
      end
    end
  end

  defp sandbox_report(report),
    do: %{status: report.status, reason: reason(report.reason), checked_at: report.checked_at}

  defp reason(nil), do: nil
  defp reason({kind, message}), do: "#{kind}: #{message}"
  defp reason(other), do: to_string(other)
end
