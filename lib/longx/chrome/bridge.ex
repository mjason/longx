defmodule Longx.Chrome.Bridge do
  @moduledoc """
  A resource without data: the settings page's view of the person's browsers
  (`Longx.Chrome`) — the paired extensions with their live state, the
  approvals, names, limits and origins, the aliases descriptions use, and
  where the extension itself is downloaded from.
  """

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.Chrome,
    extensions: [AshTypescript.Resource]

  alias Longx.Chrome
  alias Longx.Chrome.Aliases

  typescript do
    type_name "ChromeBridge"
  end

  @browsers_fields [
    # untyped: an array of typed maps cannot be selected into by ash_typescript 0.18
    browsers: [type: {:array, :map}, allow_nil?: false]
  ]

  @aliases_fields [
    aliases: [type: {:array, :map}, allow_nil?: false],
    default: [type: :string]
  ]

  @extension_fields [
    url: [type: :string, allow_nil?: false],
    version: [type: :string],
    built: [type: :boolean, allow_nil?: false],
    minimum_chrome: [type: :string, allow_nil?: false]
  ]

  @ok [ok: [type: :boolean, allow_nil?: false]]

  actions do
    action :list_chrome_browsers, :map do
      constraints fields: @browsers_fields
      run fn _input, _ -> {:ok, %{browsers: Chrome.directory()}} end
    end

    action :approve_chrome_browser, :map do
      constraints fields: @ok
      argument :id, :string, allow_nil?: false

      run fn input, _ ->
        case Chrome.approve(input.arguments.id) do
          {:ok, _browser, _token} -> {:ok, %{ok: true}}
          {:error, _} -> argument_error(:id, "no such browser")
        end
      end
    end

    action :reject_chrome_browser, :map do
      constraints fields: @ok
      argument :id, :string, allow_nil?: false

      run fn input, _ ->
        case Chrome.reject(input.arguments.id) do
          :ok -> {:ok, %{ok: true}}
          {:error, _} -> argument_error(:id, "no such browser")
        end
      end
    end

    action :revoke_chrome_browser, :map do
      constraints fields: @ok
      argument :id, :string, allow_nil?: false

      run fn input, _ ->
        case Chrome.revoke(input.arguments.id) do
          {:ok, _} -> {:ok, %{ok: true}}
          {:error, _} -> argument_error(:id, "no such browser")
        end
      end
    end

    action :rename_chrome_browser, :map do
      constraints fields: @ok
      argument :id, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false

      run fn input, _ ->
        case Chrome.rename(input.arguments.id, input.arguments.name) do
          {:ok, _} -> {:ok, %{ok: true}}
          {:error, _} -> argument_error(:name, "could not rename")
        end
      end
    end

    action :set_chrome_browser_max_tabs, :map do
      constraints fields: @ok
      argument :id, :string, allow_nil?: false
      argument :max_tabs, :integer, allow_nil?: false, constraints: [min: 1, max: 100]

      run fn input, _ ->
        case Chrome.set_max_tabs(input.arguments.id, input.arguments.max_tabs) do
          {:ok, _} -> {:ok, %{ok: true}}
          {:error, _} -> argument_error(:id, "no such browser")
        end
      end
    end

    action :set_chrome_origin, :map do
      constraints fields: @ok
      argument :id, :string, allow_nil?: false
      argument :origin, :string, allow_nil?: false
      argument :access, :atom, allow_nil?: false, constraints: [one_of: [:allow, :deny]]

      run fn input, _ ->
        case Chrome.set_origin(input.arguments.id, input.arguments.origin, input.arguments.access) do
          {:ok, _} -> {:ok, %{ok: true}}
          {:error, message} when is_binary(message) -> argument_error(:origin, message)
          {:error, _} -> argument_error(:id, "no such browser")
        end
      end
    end

    action :delete_chrome_origin, :map do
      constraints fields: @ok
      argument :id, :string, allow_nil?: false
      argument :origin, :string, allow_nil?: false

      run fn input, _ ->
        case Chrome.delete_origin(input.arguments.id, input.arguments.origin) do
          {:ok, _} -> {:ok, %{ok: true}}
          {:error, _} -> argument_error(:id, "no such browser")
        end
      end
    end

    action :chrome_aliases, :map do
      constraints fields: @aliases_fields
      run fn _input, _ -> {:ok, aliases()} end
    end

    action :set_chrome_alias, :map do
      constraints fields: @aliases_fields
      argument :name, :string, allow_nil?: false
      argument :browsers, {:array, :string}, allow_nil?: false

      run fn input, _ ->
        case Aliases.put(input.arguments.name, input.arguments.browsers) do
          :ok -> {:ok, aliases()}
          {:error, %{field: field, message: message}} -> argument_error(field, message)
        end
      end
    end

    action :delete_chrome_alias, :map do
      constraints fields: @aliases_fields
      argument :name, :string, allow_nil?: false

      run fn input, _ ->
        :ok = Aliases.delete(input.arguments.name)
        {:ok, aliases()}
      end
    end

    action :set_chrome_default_alias, :map do
      constraints fields: @aliases_fields
      argument :name, :string

      run fn input, _ ->
        case Aliases.set_default(input.arguments[:name]) do
          :ok -> {:ok, aliases()}
          {:error, %{field: field, message: message}} -> argument_error(field, message)
        end
      end
    end

    # where the extension is downloaded from, and which version that is
    action :chrome_extension, :map do
      constraints fields: @extension_fields
      run fn _input, _ -> {:ok, Chrome.extension_info()} end
    end
  end

  defp aliases, do: %{aliases: Aliases.all(), default: Aliases.default()}

  defp argument_error(field, message) do
    {:error,
     Ash.Error.Invalid.exception(
       errors: [%Ash.Error.Changes.InvalidArgument{field: field, message: message}]
     )}
  end
end
