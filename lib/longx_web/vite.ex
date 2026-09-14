defmodule LongxWeb.Vite do
  @moduledoc """
  The little that connects Vite to Phoenix (deliberately ours, not a
  dependency): the SPA shell renders `<.assets />`, which emits

    * in dev — the HMR client and the raw entry from the Vite dev server
      (`config :longx, LongxWeb.Vite, dev_server: "http://host:7789"`;
      `LONGX_DEV_HOST` makes it reachable from a phone on the LAN),
    * otherwise — the hashed files from Vite's `manifest.json`
      (`npm run build` → `priv/static/assets/`), with the entry's CSS and its
      imported chunks preloaded.

  Phoenix keeps serving everything: the page, `/rpc`, `/socket`, and in
  production the built files under `/assets` via `Plug.Static`.
  """

  use Phoenix.Component

  @type tag :: {:script | :stylesheet | :modulepreload, String.t()}

  @doc "Script/link tags for the configured entries."
  attr :entries, :list, default: nil

  def assets(assigns) do
    entries = assigns.entries || config(:entries, ["js/index.tsx"])
    tags = tags(manifest(), entries, dev_server())
    assigns = assign(assigns, :tags, tags)

    ~H"""
    <%= for tag <- @tags do %>
      <%= case tag do %>
        <% {:stylesheet, href} -> %>
          <link rel="stylesheet" href={href} />
        <% {:modulepreload, href} -> %>
          <link rel="modulepreload" href={href} />
        <% {:script, src} -> %>
          <script type="module" crossorigin src={src}>
          </script>
      <% end %>
    <% end %>
    """
  end

  @doc "The dev server base URL when one is configured (dev), else nil."
  @spec dev_server() :: String.t() | nil
  def dev_server, do: config(:dev_server, nil)

  @doc """
  Pure: the tags for `entries`. With a dev server every entry is served raw
  by Vite; otherwise the manifest says which hashed files an entry needs.
  """
  @spec tags(map, [String.t()], String.t() | nil) :: [tag]
  # The page is Phoenix's, not Vite's index.html, so the React Fast Refresh
  # preamble (@vitejs/plugin-react's "can't detect preamble" otherwise) is a
  # module of ours served by Vite, loaded before the HMR client. Module
  # scripts with `src` execute in document order.
  @react_refresh "js/dev/react-refresh.ts"

  def tags(_manifest, entries, dev_server) when is_binary(dev_server) do
    [
      {:script, dev_server <> "/" <> @react_refresh},
      {:script, dev_server <> "/@vite/client"}
      | Enum.map(entries, &{:script, dev_server <> "/" <> &1})
    ]
  end

  def tags(manifest, entries, nil) do
    Enum.flat_map(entries, fn entry ->
      chunk =
        Map.get(manifest, entry) ||
          raise "#{entry} is not in Vite's manifest — run `npm run build` in assets/ (mix assets.build)"

      imports = imported_chunks(manifest, chunk)
      styles = Enum.flat_map([chunk | imports], &Map.get(&1, "css", []))

      Enum.map(styles, &{:stylesheet, url(&1)}) ++
        entry_tag(chunk) ++ Enum.map(imports, &{:modulepreload, url(&1["file"])})
    end)
  end

  # a CSS entry's own file is a stylesheet, not a script
  defp entry_tag(%{"file" => file}) do
    if String.ends_with?(file, ".css"),
      do: [{:stylesheet, url(file)}],
      else: [{:script, url(file)}]
  end

  # transitive static imports, each once, in dependency order; `seen` holds
  # manifest keys and travels through the recursion (a plain map: dialyzer
  # loses track of an opaque MapSet inside the reduce accumulator)
  defp imported_chunks(manifest, chunk) do
    {chunks, _seen} = collect_imports(manifest, chunk, %{})
    chunks
  end

  defp collect_imports(manifest, chunk, seen) do
    chunk
    |> Map.get("imports", [])
    |> Enum.reduce({[], seen}, fn key, {acc, seen} ->
      if Map.has_key?(seen, key) do
        {acc, seen}
      else
        imported = Map.fetch!(manifest, key)
        {deeper, seen} = collect_imports(manifest, imported, Map.put(seen, key, true))
        {acc ++ deeper ++ [imported], seen}
      end
    end)
  end

  defp url(file), do: "/assets/" <> file

  # The manifest is read once per boot (prod); an absent file (nothing built
  # yet) renders no tags rather than crashing the page.
  defp manifest do
    case config(:manifest, nil) do
      nil ->
        %{}

      path ->
        key = {__MODULE__, :manifest}

        case :persistent_term.get(key, nil) do
          nil ->
            manifest = read_manifest(resolve(path))
            :persistent_term.put(key, manifest)
            manifest

          manifest ->
            manifest
        end
    end
  end

  defp read_manifest(path) do
    case File.read(path) do
      {:ok, json} -> Jason.decode!(json)
      {:error, _} -> %{}
    end
  end

  defp resolve({:priv, rel}), do: Application.app_dir(:longx, Path.join("priv", rel))
  defp resolve(path) when is_binary(path), do: Path.expand(path)

  defp config(key, default),
    do: :longx |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
