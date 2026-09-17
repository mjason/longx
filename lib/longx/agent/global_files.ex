defmodule Longx.Agent.GlobalFiles do
  @moduledoc """
  The person's global agent directory (`Longx.Agent.Loader.global_dir/0`)
  as files the settings page edits: `agent.exs`, `agents/<name>/…`,
  `plugs/*.exs` and their prompts. Paths are relative and stay inside the
  directory; knowledge has its own page.
  """

  @doc "Every file of the directory but the knowledge, with its size."
  @spec list() :: [%{path: String.t(), size: non_neg_integer}]
  def list do
    dir = Longx.Agent.Loader.global_dir()

    if File.dir?(dir) do
      for path <- dir |> Path.join("**") |> Path.wildcard(match_dot: false),
          File.regular?(path),
          rel = Path.relative_to(path, dir),
          not String.starts_with?(rel, "knowledge/"),
          Path.extname(rel) in [".exs", ".md"] do
        %{path: rel, size: File.stat!(path).size}
      end
      |> Enum.sort_by(& &1.path)
    else
      []
    end
  end

  @spec read(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read(rel) do
    with {:ok, file} <- locate(rel) do
      case File.read(file) do
        {:ok, text} -> {:ok, text}
        {:error, :enoent} -> {:error, "no file #{rel}"}
        {:error, reason} -> {:error, "cannot read #{rel}: #{:file.format_error(reason)}"}
      end
    end
  end

  @spec write(String.t(), String.t()) :: :ok | {:error, String.t()}
  def write(rel, content) when is_binary(content) do
    with {:ok, file} <- locate(rel),
         :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, content) do
      :ok
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "cannot write #{rel}: #{:file.format_error(reason)}"}

      {:error, message} ->
        {:error, message}
    end
  end

  @spec delete(String.t()) :: :ok | {:error, String.t()}
  def delete(rel) do
    with {:ok, file} <- locate(rel) do
      case File.rm(file) do
        :ok -> :ok
        {:error, :enoent} -> {:error, "no file #{rel}"}
        {:error, reason} -> {:error, "cannot delete #{rel}: #{:file.format_error(reason)}"}
      end
    end
  end

  defp locate(rel) do
    dir = Longx.Agent.Loader.global_dir()
    file = Path.expand(rel, dir)

    cond do
      not String.starts_with?(file, dir <> "/") ->
        {:error, "#{rel} is outside the agent directory"}

      Path.extname(file) not in [".exs", ".md"] ->
        {:error, "#{rel}: only .exs and .md files live here"}

      String.starts_with?(Path.relative_to(file, dir), "knowledge/") ->
        {:error, "knowledge is edited on its own page"}

      true ->
        {:ok, file}
    end
  end
end
