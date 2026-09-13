defmodule Longx.System.Directory do
  @moduledoc """
  What the UI's directory picker sees: the subdirectories of one absolute
  path on this machine, each flagged when it holds a `.git`, plus a few
  roots to jump to. Files are never listed — a project is a directory.
  """

  @type entry :: %{name: String.t(), path: Path.t(), git: boolean}
  @type listing :: %{
          path: Path.t(),
          parent: Path.t() | nil,
          git: boolean,
          entries: [entry],
          roots: [entry]
        }

  @spec list(Path.t() | nil, keyword) :: {:ok, listing} | {:error, Ash.Error.t()}
  def list(path, opts \\ []) do
    path = path || System.user_home!()
    show_hidden = Keyword.get(opts, :show_hidden, false)

    cond do
      Path.type(path) != :absolute ->
        invalid(:path, "must be an absolute path")

      not File.dir?(path) ->
        invalid(:path, "is not an existing directory")

      true ->
        path = Path.expand(path)

        entries =
          path
          |> File.ls!()
          |> Enum.filter(&(show_hidden or not String.starts_with?(&1, ".")))
          |> Enum.map(&Path.join(path, &1))
          |> Enum.filter(&File.dir?/1)
          |> Enum.sort_by(&String.downcase(Path.basename(&1)))
          |> Enum.map(&entry/1)

        {:ok,
         %{
           path: path,
           parent: parent(path),
           git: File.dir?(Path.join(path, ".git")),
           entries: entries,
           roots: roots()
         }}
    end
  end

  @doc """
  Makes `name` (one path segment — no separators, not `.`/`..`) under the
  existing absolute `parent`; refuses a name already there.
  """
  @spec create(Path.t(), String.t()) :: {:ok, entry} | {:error, Ash.Error.t()}
  def create(parent, name) do
    cond do
      Path.type(parent) != :absolute -> invalid(:parent, "must be an absolute path")
      not File.dir?(parent) -> invalid(:parent, "is not an existing directory")
      name == "" or name in [".", ".."] -> invalid(:name, "is not a directory name")
      String.contains?(name, ["/", "\\"]) -> invalid(:name, "must be a name, not a path")
      File.exists?(Path.join(parent, name)) -> invalid(:name, "already exists")
      true -> mkdir(Path.join(Path.expand(parent), name))
    end
  end

  defp mkdir(path) do
    case File.mkdir(path) do
      :ok -> {:ok, entry(path)}
      {:error, reason} -> invalid(:name, "could not create: #{:file.format_error(reason)}")
    end
  end

  defp entry(path),
    do: %{name: Path.basename(path), path: path, git: File.dir?(Path.join(path, ".git"))}

  defp parent("/"), do: nil
  defp parent(path), do: Path.dirname(path)

  defp roots do
    [System.user_home!(), "/"]
    |> Enum.uniq()
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&entry/1)
  end

  defp invalid(field, message) do
    {:error,
     Ash.Error.to_error_class(
       Ash.Error.Changes.InvalidArgument.exception(field: field, message: message)
     )}
  end
end
