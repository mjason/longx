defmodule Longx.Chrome.Aliases do
  @moduledoc """
  Names for the person's browsers, the way `Longx.AI.Aliases` names models:
  an alias maps to one or more paired browsers and resolves to the **first
  of them online**, so `qa-chrome → [the MacBook's Chrome, the desktop's]`
  is "whichever is on". A project's description names the alias
  (`plug Browser, browser: "qa-chrome"`); every Longx installation maps it
  to its own paired extension — a shared repository's description works
  for each person. `plug Browser` alone uses the default alias.

  Kept in `Longx.System.Setting` (`chrome_aliases`: `%{alias => [browser
  id]}`; `chrome_default_alias`: a name).
  """

  alias Longx.Chrome

  @key "chrome_aliases"
  @default_key "chrome_default_alias"

  @doc "Every alias with its browser ids, in name order."
  @spec all() :: [%{name: String.t(), browsers: [String.t()]}]
  def all do
    saved()
    |> Enum.map(fn {name, ids} -> %{name: name, browsers: ids} end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "The default alias's name, nil until the person picked one."
  @spec default() :: String.t() | nil
  def default do
    case Longx.System.get_setting(@default_key) do
      {:ok, %{value: name}} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  @spec set_default(String.t() | nil) :: :ok | {:error, map}
  def set_default(nil), do: clear_default()
  def set_default(""), do: clear_default()

  def set_default(name) when is_binary(name) do
    if Map.has_key?(saved(), name) do
      {:ok, _} = Longx.System.put_setting(@default_key, name)
      :ok
    else
      {:error, %{field: :name, message: "no alias named #{name}"}}
    end
  end

  defp clear_default do
    case Longx.System.get_setting(@default_key) do
      {:ok, setting} -> Longx.System.delete_setting(setting)
      _ -> :ok
    end

    :ok
  end

  @doc "Creates or replaces an alias: a name and the browsers it stands for, in order."
  @spec put(String.t(), [String.t()]) :: :ok | {:error, map}
  def put(name, ids) when is_binary(name) and is_list(ids) do
    with :ok <- check_name(name),
         :ok <- check_browsers(ids) do
      save(Map.put(saved(), name, ids))
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(name) when is_binary(name) do
    if default() == name, do: clear_default()
    save(Map.delete(saved(), name))
  end

  @doc "The browsers an alias names, as rows, in order; `[]` for an unknown alias."
  @spec browsers(String.t()) :: [Chrome.Browser.t()]
  def browsers(name) when is_binary(name) do
    ids = Map.get(saved(), name, [])
    rows = Chrome.list_browsers!() |> Map.new(&{&1.id, &1})
    ids |> Enum.map(&Map.get(rows, &1)) |> Enum.reject(&is_nil/1)
  end

  @doc """
  The browser an alias resolves to now: the first approved one that is
  online. `nil` for the alias means the default alias.
  """
  @spec resolve(String.t() | nil) ::
          {:ok, Chrome.Browser.t()}
          | {:error,
             :no_default
             | {:unknown_alias, String.t()}
             | {:offline, String.t(), [Chrome.Browser.t()]}}
  def resolve(nil) do
    case default() do
      nil -> {:error, :no_default}
      name -> resolve(name)
    end
  end

  def resolve(name) when is_binary(name) do
    case Map.fetch(saved(), name) do
      :error ->
        {:error, {:unknown_alias, name}}

      {:ok, _ids} ->
        rows = browsers(name)

        case Enum.find(rows, &(&1.status == :approved and Chrome.online?(&1.id))) do
          nil -> {:error, {:offline, name, rows}}
          browser -> {:ok, browser}
        end
    end
  end

  defp check_name(""), do: {:error, %{field: :name, message: "a name is needed"}}

  defp check_name(name) do
    if Regex.match?(~r/^[\p{L}\p{N}_-]+$/u, name),
      do: :ok,
      else: {:error, %{field: :name, message: "a name is letters, digits, _ or - (no spaces)"}}
  end

  defp check_browsers([]),
    do: {:error, %{field: :browsers, message: "an alias needs at least one browser"}}

  defp check_browsers(ids) do
    known = Chrome.list_browsers!() |> Enum.map(& &1.id)

    case Enum.reject(ids, &(&1 in known)) do
      [] ->
        :ok

      unknown ->
        {:error, %{field: :browsers, message: "unknown browsers: #{Enum.join(unknown, ", ")}"}}
    end
  end

  defp saved do
    case Longx.System.get_setting(@key) do
      {:ok, %{value: json}} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) ->
            for {k, v} <- map,
                is_binary(k),
                is_list(v),
                into: %{},
                do: {k, Enum.filter(v, &is_binary/1)}

          _ ->
            %{}
        end

      _ ->
        %{}
    end
  end

  defp save(map) do
    {:ok, _} = Longx.System.put_setting(@key, Jason.encode!(map))
    :ok
  end
end
