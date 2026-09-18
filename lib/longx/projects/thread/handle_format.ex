defmodule Longx.Projects.Thread.HandleFormat do
  @moduledoc false
  # a handle is a slug: lowercase letters, digits and dashes, 1–32 characters,
  # starting with a letter or digit — what fits in an address like
  # `deploy-health` or `<project>:main` without quoting
  use Ash.Resource.Validation

  @format ~r/^[a-z0-9][a-z0-9-]{0,31}$/

  @doc "Whether `handle` is a valid session handle."
  @spec valid?(term) :: boolean
  def valid?(handle), do: is_binary(handle) and Regex.match?(@format, handle)

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :handle) do
      nil ->
        :ok

      handle ->
        if valid?(handle),
          do: :ok,
          else: {:error, field: :handle, message: "句柄只能是小写字母、数字和短横线（1–32 个字符），以字母或数字开头"}
    end
  end
end
