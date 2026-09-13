defmodule Longx.AI.Search.Fetch do
  @moduledoc """
  Fetches one page for `web.run`'s `open` ourselves (Req) and turns it into
  text the model can read: HTML is parsed (`LazyHTML`) and reduced to its
  readable content — scripts, styles and page chrome (nav, header, footer,
  aside) dropped, block elements on their own lines, `<pre>` kept verbatim;
  text-like bodies (plain, markdown, json, xml) pass through. No search
  provider is involved, so opening a URL costs nothing and needs no key.
  """

  @text_types ~w(text/plain text/markdown text/csv application/json application/xml text/xml application/javascript)
  @drop ~w(script style noscript template svg canvas iframe nav header footer aside form button)
  @blocks ~w(p div section article main h1 h2 h3 h4 h5 h6 ul ol table blockquote dl figure figcaption)
  @lines ~w(li tr dt dd br hr)
  @default_max_bytes 2_000_000
  @timeout 20_000

  @type page :: %{title: String.t() | nil, text: String.t(), content_type: String.t()}

  @spec fetch(String.t(), keyword) :: {:ok, page} | {:error, term}
  def fetch(url, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    with :ok <- check_url(url),
         {:ok, %Req.Response{status: 200} = resp} <- request(url, max_bytes),
         {:ok, type} <- content_type(resp) do
      body =
        resp.body
        |> to_binary()
        |> binary_part(0, min(byte_size(to_binary(resp.body)), max_bytes))

      {:ok, extract(type, body)}
    else
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, %{__exception__: true} = e} -> {:error, Exception.message(e)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_url("http://" <> _), do: :ok
  defp check_url("https://" <> _), do: :ok
  defp check_url(_), do: {:error, :invalid_url}

  defp request(url, _max_bytes) do
    Req.get(url,
      receive_timeout: @timeout,
      retry: false,
      redirect: true,
      max_redirects: 5,
      decode_body: false,
      headers: [
        {"user-agent", "Longx/1.0 (+https://github.com/longx; agent web fetch)"},
        {"accept", "text/html, text/plain;q=0.9, application/json;q=0.8, */*;q=0.1"}
      ]
    )
  end

  defp content_type(%Req.Response{} = resp) do
    type =
      resp
      |> Req.Response.get_header("content-type")
      |> List.first()
      |> to_string()
      |> String.split(";")
      |> hd()
      |> String.trim()
      |> String.downcase()

    cond do
      type == "" -> {:ok, "text/html"}
      type == "text/html" or type == "application/xhtml+xml" -> {:ok, "text/html"}
      type in @text_types or String.starts_with?(type, "text/") -> {:ok, type}
      true -> {:error, {:unsupported_content_type, type}}
    end
  end

  defp to_binary(body) when is_binary(body), do: body
  defp to_binary(body), do: IO.iodata_to_binary(body)

  defp extract("text/html", html) do
    doc = LazyHTML.from_document(html)
    title = doc |> LazyHTML.query("title") |> LazyHTML.text() |> String.trim() |> blank_to_nil()

    root =
      case LazyHTML.query(doc, "main, article, [role=main]") do
        %LazyHTML{} = main -> if Enum.count(main) > 0, do: main, else: LazyHTML.query(doc, "body")
      end

    root = if Enum.count(root) == 0, do: doc, else: root

    text =
      root
      |> LazyHTML.to_tree()
      |> render()
      |> IO.iodata_to_binary()
      |> tidy()

    %{title: title, text: text, content_type: "text/html"}
  end

  defp extract(type, body), do: %{title: nil, text: body, content_type: type}

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  # tree → iodata: readable text with block structure
  defp render(nodes) when is_list(nodes), do: Enum.map(nodes, &render/1)
  defp render(text) when is_binary(text), do: text
  defp render({:comment, _}), do: []

  defp render({tag, _attrs, _children}) when tag in @drop, do: []

  defp render({"pre", _attrs, children}), do: ["\n", pre_text(children), "\n"]

  defp render({tag, _attrs, children}) when tag in @blocks,
    do: ["\n", Enum.map(children, &render/1), "\n"]

  defp render({tag, _attrs, children}) when tag in @lines,
    do: [Enum.map(children, &render/1), "\n"]

  defp render({_tag, _attrs, children}), do: Enum.map(children, &render/1)

  defp pre_text(nodes) when is_list(nodes), do: Enum.map(nodes, &pre_text/1)
  defp pre_text(text) when is_binary(text), do: text
  defp pre_text({:comment, _}), do: []
  defp pre_text({_tag, _attrs, children}), do: pre_text(children)

  # collapse runs of blank lines / inline whitespace, keep pre blocks' newlines
  defp tidy(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&Regex.replace(~r/[ \t]+/, &1, " "))
    |> Enum.join("\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end
