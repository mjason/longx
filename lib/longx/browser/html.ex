defmodule Longx.Browser.Html do
  @moduledoc """
  Reduces a rendered page to what a model should read: the `main` /
  `article` / `[role=main]` element (else `body`), without scripts, styles,
  templates, svg, iframes and page chrome (nav, header, footer, aside), and
  with only the attributes that carry meaning (`href`, `src`, `alt`, `title`,
  `aria-label`, table `colspan`/`rowspan`). Whitespace runs collapse. The
  result is HTML, not text — structure and links survive.
  """

  @drop ~w(script style noscript template svg canvas iframe object embed nav header footer aside form button input select textarea link meta)
  @keep_attrs ~w(href src alt title aria-label colspan rowspan datetime)

  @spec main(String.t()) :: String.t()
  def main(html) do
    doc = LazyHTML.from_document(html)

    root =
      pick(LazyHTML.query(doc, "main, article, [role=main]"), LazyHTML.query(doc, "body"), doc)

    root
    |> LazyHTML.to_tree()
    |> Enum.map(&prune/1)
    |> Enum.reject(&is_nil/1)
    |> LazyHTML.from_tree()
    |> LazyHTML.to_html()
    |> String.replace(~r/[ \t]*\n[ \t\n]*/, "\n")
    |> String.replace(~r/[ \t]{2,}/, " ")
    |> String.trim()
  end

  @spec title(String.t()) :: String.t() | nil
  def title(html) do
    case html
         |> LazyHTML.from_document()
         |> LazyHTML.query("title")
         |> LazyHTML.text()
         |> String.trim() do
      "" -> nil
      t -> t
    end
  end

  defp pick(first, second, fallback) do
    cond do
      Enum.count(first) > 0 -> first
      Enum.count(second) > 0 -> second
      true -> fallback
    end
  end

  defp prune(text) when is_binary(text), do: text
  defp prune({:comment, _}), do: nil

  defp prune({tag, attrs, children}) do
    if tag in @drop do
      nil
    else
      {tag, Enum.filter(attrs, fn {name, _} -> name in @keep_attrs end),
       children |> Enum.map(&prune/1) |> Enum.reject(&is_nil/1)}
    end
  end
end
