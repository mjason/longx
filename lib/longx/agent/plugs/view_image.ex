defmodule Longx.Agent.Plugs.ViewImage do
  @moduledoc """
  codex's `view_image`: a local image file goes into the model's context
  as an `input_image` (a data url), for models that take images.
  """

  use Longx.Agent.Plug

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
        {:error, "#{path}: not a supported image type (png, jpeg, gif, webp, bmp)"}

      not File.regular?(full) ->
        {:error, "#{path}: no such file"}

      File.stat!(full).size > @max_bytes ->
        {:error, "#{path}: larger than #{div(@max_bytes, 1024 * 1024)} MB"}

      true ->
        data = File.read!(full)
        {:ok, "attached #{path}", %{"image" => "data:#{mime};base64," <> Base.encode64(data)}}
    end
  end
end
