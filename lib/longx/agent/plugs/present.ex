defmodule Longx.Agent.Plugs.Present do
  @moduledoc """
  Cards for the person: `present` draws a generative UI tree — a table, a
  row of facts, a chart, a form — from assistant-ui's component vocabulary
  (`@assistant-ui/react-generative-ui`), and `prompt_user` draws one and
  waits for what the person fires in it (a choice, a form). The schema of
  both is `priv/agent/present.json`, generated from the same library the
  client renders with (`npm run present-schema` in `assets/`, checked by
  `mix precommit`), so the model can only name what the page can draw.

  The tree is the call's arguments; the item the person sees is the
  `longx.present` / `longx.prompt_user` tool call itself, and the model
  reads only "shown to the user" (or the person's answer). A plug's own
  code pushes a card without the model through `Longx.Agent.Context.present/2`.

  Four more surfaces open something for the person instead of drawing in
  the chat: `show_file` / `show_diff` (a tab of the workbench), `send_file`
  (a download — `GET /files/:project_id/*path`, `LongxWeb.FileController`),
  `show_html` (an artifact: html of the model's own in a sandboxed frame,
  or a URL). Every path is checked to stay inside the project root (the
  attachment directory for a download); what the client needs — the
  project-relative path, the size, the kind — rides on the item as
  `details`, and the client opens the surface only when the item arrives
  live, never on a replay.
  """

  alias Longx.Projects.{Attachments, Workspace}

  @max_html 512 * 1024

  use Longx.Agent.Plug

  @schema_path Path.join(:code.priv_dir(:longx), "agent/present.json")
  @external_resource @schema_path
  @vocabulary Jason.decode!(File.read!(@schema_path))

  @ask_timeout 600_000

  instructions """
  # Cards for the person

  `present` draws a card in the conversation from a fixed component vocabulary (`$type`: Card, Row, Col, Fact, Table, Chart, Markdown, Alert, Badge, ListView, Image, …; nest with `children`). Use it when a structure says it better than prose: a comparison or any tabular data (Table), a few key numbers (Facts in a Row), a trend (Chart), a status or warning (Alert), code or a longer formatted passage (Markdown, with fenced code). Keep trees small and say the conclusion in words as well — the card is not a substitute for the answer. Plain conversation, short lists and file contents stay prose.

  `prompt_user` draws a card the person acts on and waits for the answer: a choice (Buttons with `$action`, a Select, a RadioGroup), a form (a Card with `asForm` and `confirm`, or a Form) — use it when you need a decision or values from the person before going on; the result is what they fired (`type` of the `$action`, `$input` with the value or the form's values). Do not use it for yes / no questions you can simply ask in text.

  Opening things for the person, instead of pasting them into the chat: `show_file(path, line)` opens a file of the project in their editor (they asked to see it, or a result worth reading in full — say which part in words); `show_diff(path, sha)` opens what changed in a file (the working tree against HEAD, or one commit); `send_file(path, title)` hands them a file to download — an output they keep (a csv, a report, an image, a zip you built; write it under the project first); `show_html(title, html | url)` opens an artifact surface — a chart, a report, an interactive page you wrote as one self-contained html (inline css / js, no external requests), or a URL to look at. A file's content still goes into your answer when it is short and the point.
  """

  tool :present, @vocabulary["present"]["description"],
    namespace: "longx",
    schema: @vocabulary["present"]["parameters"],
    prepare: &__MODULE__.normalize/1 do
  end

  tool :prompt_user, @vocabulary["prompt_user"]["description"],
    namespace: "longx",
    schema: @vocabulary["prompt_user"]["parameters"],
    prepare: &__MODULE__.normalize/1,
    timeout: @ask_timeout + 5_000 do
  end

  tool :show_file,
       "Opens a file of the project in the person's editor (the workbench), optionally at a line. Use it instead of pasting a long file into the chat.",
       namespace: "longx" do
    param :path,
          :string,
          "Path of the file, relative to the working directory or absolute (inside the project)",
          required: true

    param :line, :integer, "Line to scroll to (1-based)"
  end

  tool :show_diff,
       "Opens the diff of one file for the person: the working tree against HEAD, or what a commit did to it when `sha` is given.",
       namespace: "longx" do
    param :path,
          :string,
          "Path of the file, relative to the working directory or absolute (inside the project)",
          required: true

    param :sha, :string, "A commit sha (7–40 hex chars); none means the uncommitted change"
  end

  tool :send_file,
       "Hands the person a file to download (a result they keep: a csv, a report, an image, an archive). The file must be inside the project, or one of the message's attachments.",
       namespace: "longx" do
    param :path, :string, "Path of the file, relative to the working directory or absolute",
      required: true

    param :title, :string, "A short title for the download card"
  end

  tool :show_html,
       "Opens an artifact surface for the person: a self-contained html page you wrote (a chart, a report, an interactive page — inline css and js, at most 512 KB) or an http(s) URL. Exactly one of `html` / `url`.",
       namespace: "longx" do
    param :title, :string, "What the surface is", required: true
    param :html, :string, "The whole html document"
    param :url, :string, "An http(s) URL to show instead"
  end

  @doc "The component names the vocabulary offers."
  @spec components() :: [String.t()]
  def components, do: @vocabulary["components"]

  def present(_tree, _ctx), do: {:ok, "shown to the user"}

  # the keys whose values are structure, never prose: a JSON string there is
  # a model's serialisation slip (百炼 and DeepSeek send nested arrays as
  # strings now and then — a card once showed its children as raw JSON)
  @structural ~w(children rows columns options data items series fields steps actions confirm cancel $action)

  @doc """
  A tree as the model meant it: nested arrays / objects sent as JSON
  strings decoded (for the structural keys only — a Text whose value looks
  like JSON stays text), and a tree handed over under a single key
  (`spec`, `tree`) or as one string unwrapped. Applied before validation
  and before the UI item is made.
  """
  @spec normalize(term) :: term
  def normalize(%{"$type" => _} = node), do: normalize_node(node)

  def normalize(map) when is_map(map) and map_size(map) == 1 do
    case map |> Map.values() |> hd() |> decode_if_json() do
      %{"$type" => _} = node -> normalize_node(node)
      _ -> normalize_node(map)
    end
  end

  def normalize(other), do: normalize_node(other)

  defp normalize_node(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when key in @structural -> {key, value |> decode_if_json() |> normalize_node()}
      {key, value} -> {key, normalize_node(value)}
    end)
  end

  defp normalize_node(list) when is_list(list), do: Enum.map(list, &normalize_node/1)
  defp normalize_node(other), do: other

  defp decode_if_json(text) when is_binary(text) do
    case String.trim(text) do
      <<c, _::binary>> = trimmed when c in [?[, ?{] ->
        case Jason.decode(trimmed) do
          {:ok, decoded} when is_map(decoded) or is_list(decoded) -> decoded
          _ -> text
        end

      _ ->
        text
    end
  end

  defp decode_if_json(other), do: other

  def prompt_user(tree, ctx) do
    case Context.ask(ctx, title: title_of(tree), spec: tree, timeout: @ask_timeout) do
      {:ok, %{"action" => action}} -> {:ok, Jason.encode!(action)}
      {:ok, answer} -> {:ok, Jason.encode!(answer)}
      {:error, :cancelled} -> {:error, "the person dismissed it without answering"}
      {:error, :timeout} -> {:error, "no answer from the person within the time"}
      {:error, :no_agent} -> {:error, "no agent to ask the person through"}
    end
  end

  defp title_of(%{"title" => title}) when is_binary(title) and title != "", do: title
  defp title_of(_tree), do: "需要你选择"

  ## Surfaces

  def show_file(%{"path" => path} = args, ctx) do
    with {:ok, rel, full} <- inside_project(ctx, path),
         :ok <- regular(full, path) do
      details = %{"path" => rel, "line" => line_of(args)}
      {:ok, "opened #{rel} for the person", %{"details" => details}}
    end
  end

  def show_diff(%{"path" => path} = args, ctx) do
    with {:ok, rel, _full} <- inside_project(ctx, path),
         {:ok, sha} <- sha_of(args) do
      {:ok, "opened the diff of #{rel} for the person",
       %{"details" => %{"path" => rel, "sha" => sha}}}
    end
  end

  def send_file(%{"path" => path} = args, ctx) do
    with {:ok, rel, full, attachment?} <- sendable(ctx, path),
         :ok <- regular(full, path) do
      bytes = File.stat!(full).size

      details = %{
        "path" => rel,
        "name" => display_name(full, attachment?),
        "bytes" => bytes,
        "mime" => MIME.from_path(full),
        "attachment" => attachment?,
        "title" => args["title"]
      }

      {:ok, "sent #{details["name"]} to the person (#{bytes} B)", %{"details" => details}}
    end
  end

  def show_html(%{"title" => title} = args, _ctx) do
    case {args["html"], args["url"]} do
      {html, _} when is_binary(html) and html != "" and byte_size(html) > @max_html ->
        {:error,
         "the html is #{div(byte_size(html), 1024)} KB; at most 512 KB — write it to a file and send_file it instead"}

      {html, _} when is_binary(html) and html != "" ->
        {:ok, "opened #{title} for the person",
         %{"details" => %{"kind" => "html", "title" => title, "bytes" => byte_size(html)}}}

      {_, url} when is_binary(url) and url != "" ->
        if Regex.match?(~r{^https?://}i, url),
          do:
            {:ok, "opened #{title} for the person",
             %{"details" => %{"kind" => "url", "title" => title, "url" => url}}},
          else: {:error, "only http(s) URLs can be shown"}

      _ ->
        {:error, "give html or url"}
    end
  end

  # the project root: the project's, else the working directory (tests)
  defp root(%{project_id: id, cwd: cwd}) do
    with true <- is_binary(id),
         {:ok, %{root_path: root}} <- Ash.get(Longx.Projects.Project, id, authorize?: false) do
      Path.expand(root)
    else
      _ -> Path.expand(cwd || ".")
    end
  end

  # a path the model gave, as project-relative + absolute, provided it stays inside
  defp inside_project(ctx, path) do
    root = root(ctx)
    full = Path.expand(path, ctx.cwd || root)
    rel = Path.relative_to(full, root)

    case Workspace.resolve(root, rel) do
      {:ok, ^full} ->
        {:ok, rel, full}

      _ ->
        {:error,
         "#{path}: outside the project (or inside .git) — only project files can be opened"}
    end
  end

  defp sendable(%{project_id: id} = ctx, path) when is_binary(id) do
    full = Path.expand(path, ctx.cwd || ".")
    dir = Path.expand(Attachments.dir(id))

    if Path.dirname(full) == dir,
      do: {:ok, Path.basename(full), full, true},
      else: with({:ok, rel, full} <- inside_project(ctx, path), do: {:ok, rel, full, false})
  end

  defp sendable(ctx, path),
    do: with({:ok, rel, full} <- inside_project(ctx, path), do: {:ok, rel, full, false})

  defp regular(full, path) do
    cond do
      File.regular?(full) -> :ok
      File.dir?(full) -> {:error, "#{path}: not a file"}
      true -> {:error, "#{path}: no such file"}
    end
  end

  # an attachment is stored as <stamp>-<name>: the person knows it by its name
  defp display_name(full, true),
    do: full |> Path.basename() |> String.replace(~r/^\d{8}T\d{6}-/, "")

  defp display_name(full, false), do: Path.basename(full)

  defp line_of(%{"line" => line}) when is_integer(line) and line > 0, do: line
  defp line_of(_args), do: nil

  defp sha_of(%{"sha" => sha}) when is_binary(sha) and sha != "" do
    if Regex.match?(~r/^[0-9a-f]{7,40}$/i, sha),
      do: {:ok, String.downcase(sha)},
      else:
        {:error,
         "#{sha}: not a commit sha (7–40 hex chars); leave it out for the uncommitted change"}
  end

  defp sha_of(_args), do: {:ok, nil}
end
