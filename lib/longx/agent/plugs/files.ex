defmodule Longx.Agent.Plugs.Files do
  @moduledoc """
  The file tools: `read_file` (a range of lines, capped), `write_file`
  (whole file, parents created) and `edit_file` (an exact string replaced
  once, or everywhere with `replace_all`). Paths are relative to the
  working directory or absolute. Writes and edits show as file changes in
  the UI; a read as a plain tool row.
  """

  use Longx.Agent.Plug

  @max_read 200 * 1024

  tool :read_file,
       "Reads a text file. Returns the whole file, or `limit` lines from line `offset` (1-based).",
       show: :tool do
    param(:path, :string, "File path, relative to the working directory or absolute",
      required: true
    )

    param :offset, :integer, "First line to return (1-based)"
    param :limit, :integer, "How many lines to return"
  end

  tool :write_file,
       "Writes a whole file (created with its directories when missing, replaced otherwise).",
       show: :file_change do
    param :path, :string, "File path", required: true
    param :content, :string, "The complete new content", required: true
  end

  tool :edit_file,
       "Replaces `old_string` with `new_string` in a file. old_string must occur exactly once unless replace_all is true; copy it exactly from read_file, whitespace included.",
       show: :file_change do
    param :path, :string, "File path", required: true
    param :old_string, :string, "The exact text to replace", required: true
    param :new_string, :string, "The replacement", required: true
    param :replace_all, :boolean, "Replace every occurrence"
  end

  def read_file(%{"path" => path} = args, ctx) do
    full = Context.path(ctx, path)

    case File.read(full) do
      {:ok, content} ->
        cond do
          binary?(content) -> {:error, "#{path} is a binary file (#{byte_size(content)} bytes)"}
          true -> {:ok, slice(content, args["offset"], args["limit"])}
        end

      {:error, reason} ->
        {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  def write_file(%{"path" => path, "content" => content}, ctx) do
    full = Context.path(ctx, path)
    kind = if File.exists?(full), do: "update", else: "add"

    with :ok <- File.mkdir_p(Path.dirname(full)),
         :ok <- File.write(full, content) do
      {:ok, "wrote #{byte_size(content)} bytes to #{path}", changes(full, kind)}
    else
      {:error, reason} -> {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end

  def edit_file(%{"path" => path, "old_string" => old, "new_string" => new} = args, ctx) do
    full = Context.path(ctx, path)
    all? = args["replace_all"] == true

    with {:ok, content} <- read_for_edit(full, path),
         {:ok, replaced, count} <- replace(content, old, new, all?),
         :ok <- File.write(full, replaced) do
      {:ok, "replaced #{count} occurrence#{plural(count)} in #{path}", changes(full, "update")}
    end
  end

  defp read_for_edit(full, path) do
    case File.read(full) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp replace(_content, "", _new, _all?), do: {:error, "old_string must not be empty"}

  defp replace(content, old, new, all?) do
    case length(:binary.matches(content, old)) do
      0 ->
        {:error, "old_string not found in the file; read it and copy the text exactly"}

      1 ->
        {:ok, String.replace(content, old, new, global: false), 1}

      n when all? ->
        {:ok, String.replace(content, old, new), n}

      n ->
        {:error,
         "old_string occurs #{n} times; include more context to make it unique, or set replace_all"}
    end
  end

  defp changes(full, kind), do: %{"changes" => [%{"path" => full, "kind" => kind}]}

  defp binary?(content) do
    head = binary_part(content, 0, min(byte_size(content), 8_192))
    String.contains?(head, <<0>>) or not String.valid?(head)
  end

  defp slice(content, nil, nil) when byte_size(content) <= @max_read, do: content

  defp slice(content, nil, nil),
    do:
      binary_part(content, 0, @max_read) <>
        "\n\n[truncated: #{byte_size(content)} bytes in file; read a range with offset/limit]"

  defp slice(content, offset, limit) do
    lines = String.split(content, "\n")
    from = max((offset || 1) - 1, 0)
    taken = if limit, do: Enum.slice(lines, from, limit), else: Enum.drop(lines, from)
    text = Enum.join(taken, "\n")
    # a line followed by another (or by the file's final newline) keeps its newline
    text = if limit && from + limit < length(lines), do: text <> "\n", else: text
    slice(text, nil, nil)
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
