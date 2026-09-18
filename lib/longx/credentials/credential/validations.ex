defmodule Longx.Credentials.Credential.Validations do
  @moduledoc false

  defmodule Hosts do
    @moduledoc """
    `allowed_hosts` must name at least one hostname: a credential nobody
    may send anywhere is useless, and one that may go anywhere is a leak.
    Runs after `NormaliseHosts` (validations follow changes).
    """
    use Ash.Resource.Validation

    alias Longx.Credentials.Credential.Changes.NormaliseHosts

    @impl true
    def validate(changeset, _opts, _ctx) do
      case Ash.Changeset.fetch_argument_or_change(changeset, :allowed_hosts) do
        {:ok, hosts} when is_list(hosts) ->
          if NormaliseHosts.normalise(hosts) == [],
            do: {:error, field: :allowed_hosts, message: "name at least one host"},
            else: :ok

        {:ok, _other} ->
          {:error, field: :allowed_hosts, message: "must be a list of hosts"}

        :error ->
          if changeset.action_type == :create,
            do: {:error, field: :allowed_hosts, message: "name at least one host"},
            else: :ok
      end
    end
  end
end
