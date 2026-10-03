defmodule Longx.Agent.Plugs.Computer do
  @moduledoc """
  Opt-in desktop use through the configured Longx Computer HTTP MCP service.
  `plug Computer` adds the live, curated Driver tools without embedding another
  agent loop. Screenshots use the same model/UI attachment path as Browser.
  """
  use Longx.Agent.Plug

  alias Longx.Computer.{Connection, Pool}

  @external_resource "priv/agent/computer/prompt.md"
  @prompt File.read!("priv/agent/computer/prompt.md")
  @hidden ~w(session screenshot_out_file debug_image_out _session_id _transport_session_id)

  tool :computer_status,
       "Check the configured computer service and permissions. Does not start an app or grant permissions." do
  end

  @impl true
  def call(%Step{phase: :request} = step, opts) do
    step = Longx.Agent.Plug.mount(step, __MODULE__) |> Step.instructions(@prompt)
    name = Keyword.get(opts, :computer)
    target = Pool.resolve({step.thread_id, step.turn_id}, name)
    label = name || "default"

    step =
      Step.instructions(
        step,
        "Computer alias: #{label}. A turn stays on its selected computer; never replay input on a different machine."
      )

    status_tool = step.tools["computer_status"]

    step =
      Step.tool(step, %{
        status_tool
        | fun: fn _, _ ->
            case target do
              {:ok, id} ->
                {:ok,
                 Jason.encode!(%{computer: id, alias: label, connection: Connection.status(id)})}

              {:error, reason} ->
                {:error, reason}
            end
          end
      })

    tools =
      case target do
        {:ok, id} -> Connection.catalog(id)
        _ -> []
      end

    generation =
      case target do
        {:ok, id} -> Connection.generation(id)
        _ -> nil
      end

    Enum.reduce(tools, step, fn definition, step ->
      name = definition["name"]
      schema = definition["inputSchema"]

      schema =
        schema
        |> Map.update("properties", %{}, &Map.drop(&1, @hidden))
        |> Map.update("required", [], &(&1 -- @hidden))

      Step.tool(step, %Tool{
        name: "computer_" <> name,
        namespace: "computer",
        description: definition["description"],
        schema: schema,
        timeout: 45_000,
        fun: fn args, ctx ->
          {:ok, id} = target
          execute(id, name, args, ctx, generation)
        end
      })
    end)
  end

  def call(step, _opts), do: step

  def computer_status(_args, _ctx), do: {:ok, Jason.encode!(Connection.status())}

  def execute(_name, _args, %{thread_id: nil}),
    do: {:error, "computer control belongs to a conversation"}

  def execute(name, args, ctx) do
    execute("local", name, args, ctx)
  end

  def execute(id, name, args, ctx, generation \\ nil) do
    owner = {ctx.thread_id, ctx.turn_id}

    result =
      if generation,
        do: Connection.call(id, owner, name, args, generation),
        else: Connection.call(id, owner, name, args)

    case result do
      {:ok, result} -> format(result, name, ctx)
      {:error, message} -> {:error, message}
    end
  catch
    :exit, _ ->
      {:error,
       "the computer connection ended; input may have happened. Reconnect and observe, do not replay."}
  end

  def format(result, name, ctx) do
    content = Map.get(result, "content", [])

    images =
      for %{"type" => "image", "mimeType" => mime, "data" => data} <- content,
          mime in ["image/png", "image/jpeg", "image/webp"],
          do: {mime, data}

    text = for %{"type" => "text", "text" => text} <- content, do: text
    structured = result["structuredContent"]
    # Preserve tokens, geometry, effect and refusal diagnostics as structured JSON.
    text = if structured, do: [Jason.encode!(structured) | text], else: text
    text = Enum.join(text, "\n")
    text = if text == "", do: "(no text; inspect the attached image)", else: text

    meta = %{
      "images" => Enum.map(images, fn {mime, data} -> "data:#{mime};base64,#{data}" end),
      "details" => %{
        "title" => "Computer · #{name}",
        "screenshots" => store_images(images, ctx)
      }
    }

    if result["isError"] == true, do: {:error, text, meta}, else: {:ok, text, meta}
  end

  defp store_images(images, %{project_id: project}) when is_binary(project) do
    Enum.flat_map(images, fn {mime, data} ->
      ext =
        if mime == "image/png", do: "png", else: if(mime == "image/webp", do: "webp", else: "jpg")

      with {:ok, bytes} <- Base.decode64(data),
           {:ok, %{name: name, bytes: size}} <-
             Longx.Projects.Attachments.store_bytes(project, "computer.#{ext}", bytes) do
        [%{"name" => name, "path" => name, "attachment" => true, "mime" => mime, "bytes" => size}]
      else
        _ -> []
      end
    end)
  end

  defp store_images(_, _), do: []
end
