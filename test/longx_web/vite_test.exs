defmodule LongxWeb.ViteTest do
  # Our own (small) Vite ↔ Phoenix glue: which tags the SPA shell renders.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias LongxWeb.Vite

  @manifest Jason.decode!(File.read!("test/support/vite_manifest.json"))

  describe "tags/3 (pure)" do
    test "dev server: the HMR client and the raw entry, both from Vite" do
      assert Vite.tags(%{}, ["js/index.tsx"], "http://localhost:5173") == [
               {:script, "http://localhost:5173/@vite/client"},
               {:script, "http://localhost:5173/js/index.tsx"}
             ]
    end

    test "manifest: hashed entry, its css, imported chunks preloaded with their css" do
      assert Vite.tags(@manifest, ["js/index.tsx"], nil) == [
               {:stylesheet, "/assets/index-C0hg9Xz1.css"},
               {:stylesheet, "/assets/vendor-Q2rTs8Yp.css"},
               {:script, "/assets/index-BvxhF3aQ.js"},
               {:modulepreload, "/assets/vendor-Dk3lqR5m.js"}
             ]
    end

    test "a css entry is just a stylesheet" do
      assert Vite.tags(@manifest, ["css/app.css"], nil) == [
               {:stylesheet, "/assets/app-Z9y8x7w6.css"}
             ]
    end

    test "an entry missing from the manifest raises with a hint to build" do
      assert_raise RuntimeError, ~r/npm run build/, fn ->
        Vite.tags(@manifest, ["js/nope.tsx"], nil)
      end
    end
  end

  describe "assets/1 component" do
    import Phoenix.Component, only: [sigil_H: 2]

    test "renders script/link tags for the configured entries" do
      assigns = %{}
      html = rendered_to_string(~H"<LongxWeb.Vite.assets />")
      assert html =~ ~r{<script[^>]*type="module"[^>]*src="/assets/index-BvxhF3aQ.js"}
      assert html =~ ~r{<link[^>]*rel="stylesheet"[^>]*href="/assets/index-C0hg9Xz1.css"}
      assert html =~ ~r{<link[^>]*rel="modulepreload"[^>]*href="/assets/vendor-Dk3lqR5m.js"}
    end
  end
end
