defmodule Longx.Projects.Attachments do
  @moduledoc """
  Files attached to a message that are neither an image (sent to the model
  as a data url) nor a text file (inlined): a zip, a PDF, a dataset. The
  composer uploads them to `POST /attachments/:project_id`
  (`LongxWeb.AttachmentController`) and they land under
  `<attachments dir>/<project id>/<stamp>-<name>` — in the data directory
  (`config :longx, Longx.Projects.Attachments, dir:`; dev `data/attachments`,
  prod `$LONGX_DATA_DIR/attachments`), never in the working directory, so
  the repository stays clean. The message names the path: a sandboxed
  command reads it (`/` is read-only in the sandbox) but cannot delete it.
  Deleting the project removes the directory (`Changes.DeleteAttachments`).
  """

  @doc "The attachment directory (configured; default `data/attachments`)."
  @spec root() :: Path.t()
  def root do
    :longx
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:dir, Path.expand("data/attachments"))
  end

  @doc "A project's attachment directory."
  @spec dir(String.t()) :: Path.t()
  def dir(project_id), do: Path.join(root(), project_id)

  @doc """
  Stores an uploaded file for the project: `<stamp>-<name>` under its
  directory, `name` reduced to a file name (no path separators; empty →
  `attachment`). Answers the absolute path and the size.
  """
  @spec store(String.t(), Path.t(), String.t()) ::
          {:ok, %{path: Path.t(), name: String.t(), bytes: non_neg_integer}} | {:error, term}
  def store(project_id, source, name) do
    name = safe_name(name)
    stamp = DateTime.utc_now() |> DateTime.truncate(:second) |> Calendar.strftime("%Y%m%dT%H%M%S")
    dest = Path.join(dir(project_id), "#{stamp}-#{name}")

    with :ok <- File.mkdir_p(dir(project_id)),
         :ok <- File.cp(source, dest),
         {:ok, %{size: bytes}} <- File.stat(dest) do
      {:ok, %{path: dest, name: name, bytes: bytes}}
    end
  end

  @doc "Removes everything the project ever attached."
  @spec delete_all(String.t()) :: :ok
  def delete_all(project_id) do
    File.rm_rf!(dir(project_id))
    :ok
  end

  # the browser's file name, kept as typed (unicode, spaces) minus anything
  # that could leave the directory
  defp safe_name(name) do
    name
    |> to_string()
    |> String.replace(["\\", "/"], "/")
    |> Path.basename()
    |> String.replace(~r/[\x00-\x1f]/, "")
    |> String.trim()
    |> case do
      "" -> "attachment"
      "." -> "attachment"
      ".." -> "attachment"
      safe -> safe
    end
  end
end
