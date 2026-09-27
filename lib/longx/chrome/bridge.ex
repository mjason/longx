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
    extensions: [AshGraphql.Resource]

  alias Longx.Chrome
  alias Longx.Chrome.{Aliases, Types}

  # no rows, no object type: only its generic actions are in the schema
  graphql do
    generate_object? false
  end

  actions do
    action :list_chrome_browsers, Types.Browsers do
      run fn _input, _ -> {:ok, %{browsers: Chrome.directory()}} end
    end

    action :approve_chrome_browser, Types.Ok do
      argument :id, :string, allow_nil?: false

      run fn input, _ ->
        case Chrome.approve(input.arguments.id) do
          {:ok, _browser, _token} -> {:ok, %{ok: true}}
          {:error, _} -> argument_error(:id, "no such browser")
        end
      end
    end

    action :reject_chrome_browser, Types.Ok do
      argument :id, :string, allow_nil?: false

      run fn input, _ ->
        case Chrome.reject(input.arguments.id) do
          :ok -> {:ok, %{ok: true}}
          {:error, _} -> argument_error(:id, "no such browser")
        end
      end
    end

    action :revoke_chrome_browser, Types.Ok do
      argument :id, :string, allow_nil?: false

      run fn input, _ ->
        case Chrome.revoke(input.arguments.id) do
          {:ok, _} -> {:ok, %{ok: true}}
          {:error, _} -> argument_error(:id, "no such browser")
        end
      end
    end

    action :rename_chrome_browser, Types.Ok do
      argument :id, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false

      run fn input, _ ->
        case Chrome.rename(input.arguments.id, input.arguments.name) do
          {:ok, _} -> {:ok, %{ok: true}}
          {:error, _} -> argument_error(:name, "could not rename")
        end
      end
    end

    action :set_chrome_browser_max_tabs, Types.Ok do
      argument :id, :string, allow_nil?: false
      argument :max_tabs, :integer, allow_nil?: false, constraints: [min: 1, max: 100]

      run fn input, _ ->
        case Chrome.set_max_tabs(input.arguments.id, input.arguments.max_tabs) do
          {:ok, _} -> {:ok, %{ok: true}}
          {:error, _} -> argument_error(:id, "no such browser")
        end
      end
    end

    action :set_chrome_origin, Types.Ok do
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

    action :delete_chrome_origin, Types.Ok do
      argument :id, :string, allow_nil?: false
      argument :origin, :string, allow_nil?: false

      run fn input, _ ->
        case Chrome.delete_origin(input.arguments.id, input.arguments.origin) do
          {:ok, _} -> {:ok, %{ok: true}}
          {:error, _} -> argument_error(:id, "no such browser")
        end
      end
    end

    action :chrome_aliases, Types.Aliases do
      run fn _input, _ -> {:ok, aliases()} end
    end

    action :set_chrome_alias, Types.Aliases do
      argument :name, :string, allow_nil?: false
      argument :browsers, {:array, :string}, allow_nil?: false

      run fn input, _ ->
        case Aliases.put(input.arguments.name, input.arguments.browsers) do
          :ok -> {:ok, aliases()}
          {:error, %{field: field, message: message}} -> argument_error(field, message)
        end
      end
    end

    action :delete_chrome_alias, Types.Aliases do
      argument :name, :string, allow_nil?: false

      run fn input, _ ->
        :ok = Aliases.delete(input.arguments.name)
        {:ok, aliases()}
      end
    end

    action :set_chrome_default_alias, Types.Aliases do
      argument :name, :string

      run fn input, _ ->
        case Aliases.set_default(input.arguments[:name]) do
          :ok -> {:ok, aliases()}
          {:error, %{field: field, message: message}} -> argument_error(field, message)
        end
      end
    end

    # where the extension is downloaded from, and which version that is
    action :chrome_extension, Types.Extension do
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
