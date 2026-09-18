defmodule Longx.Credentials.Credential.Changes do
  @moduledoc false

  defmodule NormaliseHosts do
    @moduledoc "Hosts as lowercase hostnames: a pasted URL is reduced to its host, blanks dropped."
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _ctx) do
      case Ash.Changeset.fetch_change(changeset, :allowed_hosts) do
        {:ok, hosts} when is_list(hosts) ->
          Ash.Changeset.force_change_attribute(changeset, :allowed_hosts, normalise(hosts))

        _ ->
          changeset
      end
    end

    @doc "The hosts a person typed, one hostname each (a URL gives its host)."
    @spec normalise([String.t()]) :: [String.t()]
    def normalise(hosts) do
      hosts
      |> Enum.map(&host_of/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end

    defp host_of(value) when is_binary(value) do
      trimmed = value |> String.trim() |> String.downcase()

      case URI.parse(trimmed) do
        %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) -> host
        _ -> trimmed |> String.split("/") |> hd() |> String.split(":") |> hd()
      end
    end

    defp host_of(_), do: ""
  end
end
