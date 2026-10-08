defmodule Longx.Agent.Plugs.ViewImage do
  @moduledoc """
  codex's `view_image`: a local image file goes into the model's context
  as an `input_image` (a data url), for models that take images.
  """

  use Longx.Agent.Plug
  alias Longx.Projects.Attachments

  @max_bytes 20 * 1024 * 1024
  @mime %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".bmp" => "image/bmp"
  }

  # codex's words (core/src/tools/handlers/view_image_spec.rs)
  tool :view_image,
       "View a local image file from the filesystem when visual inspection is needed. Use this for images already available on disk." do
    param :path, :string, "Local filesystem path to an image file.", required: true
  end

  def view_image(%{"path" => path}, ctx) do
    full = Context.path(ctx, path)
    mime = Map.get(@mime, full |> Path.extname() |> String.downcase())

    cond do
      mime == nil ->
        error(path, "unsupported_image", "not a supported image type (png, jpeg, gif, webp, bmp)")

      not File.regular?(full) ->
        error(path, "not_found", "no such file")

      File.stat!(full).size > @max_bytes ->
        error(path, "too_large", "larger than #{div(@max_bytes, 1024 * 1024)} MB")

      true ->
        data = File.read!(full)

        {:ok, "attached #{path}",
         %{
           "image" => "data:#{mime};base64," <> Base.encode64(data),
           "details" => preview(ctx.project_id, full, mime, data)
         }}
    end
  end

  # Serve a snapshot of exactly the bytes the model saw, not an arbitrary local
  # path or a file that might have changed since the call. Reuse the project's
  # attachment boundary; never put another base64 copy in the UI transcript.
  defp preview(project_id, full, mime, data) do
    details = %{"name" => Path.basename(full), "mime" => mime, "bytes" => byte_size(data)}

    with {:ok, project_id} <- Ecto.UUID.cast(project_id),
         {:ok, stored} <-
           Attachments.store_bytes(
             project_id,
             "view-#{Ash.UUID.generate()}-#{Path.basename(full)}",
             data
           ) do
      Map.merge(details, %{"path" => stored.name, "attachment" => true})
    else
      _ -> Map.put(details, "preview_unavailable", true)
    end
  end

  defp error(path, code, message) do
    {:error, "#{path}: #{message}",
     %{"details" => %{"name" => Path.basename(path), "error" => code}}}
  end
end
