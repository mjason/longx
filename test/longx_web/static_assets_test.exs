defmodule LongxWeb.StaticAssetsTest do
  # What a browser on a weak network downloads: the built scripts compressed
  # (the .br / .gz the build writes beside them) and kept for good (their
  # names carry their hash); the page shell always asked again. At 1.5 Mbps
  # the 3.7 MB entry of 0.2.64, sent raw, took 21 s.
  use LongxWeb.ConnCase, async: false

  @dir Application.app_dir(:longx, "priv/static/assets")

  setup do
    File.mkdir_p!(@dir)
    name = "zz-static-test-#{System.unique_integer([:positive])}.js"
    body = String.duplicate("export const x = 1;\n", 500)
    File.write!(Path.join(@dir, name), body)
    File.write!(Path.join(@dir, name <> ".gz"), :zlib.gzip(body))
    File.write!(Path.join(@dir, name <> ".br"), "brotli bytes")
    on_exit(fn -> for ext <- ["", ".gz", ".br"], do: File.rm(Path.join(@dir, name <> ext)) end)
    %{name: name, body: body}
  end

  test "a built script goes out as brotli or gzip, whichever the browser takes, and is kept for good",
       %{conn: conn, name: name, body: body} do
    br = conn |> put_req_header("accept-encoding", "gzip, deflate, br") |> get("/assets/" <> name)
    assert br.status == 200
    assert get_resp_header(br, "content-encoding") == ["br"]
    assert br.resp_body == "brotli bytes"
    assert get_resp_header(br, "cache-control") == ["public, max-age=31536000, immutable"]

    gz = build_conn() |> put_req_header("accept-encoding", "gzip") |> get("/assets/" <> name)
    assert get_resp_header(gz, "content-encoding") == ["gzip"]
    assert :zlib.gunzip(gz.resp_body) == body

    plain = build_conn() |> get("/assets/" <> name)
    assert get_resp_header(plain, "content-encoding") == []
    assert plain.resp_body == body
  end

  test "the page shell is asked for again every time (it names the scripts of the running version)",
       %{conn: conn} do
    shell = conn |> put_req_header("accept", "text/html") |> get("/")
    refute Enum.any?(get_resp_header(shell, "cache-control"), &(&1 =~ "immutable"))
  end

  test "the socket compresses its frames (a long thread's snapshot is megabytes of JSON)" do
    {_path, LongxWeb.UserSocket, opts} =
      Enum.find(LongxWeb.Endpoint.__sockets__(), fn {path, _, _} -> path == "/socket" end)

    assert opts[:websocket][:compress] == true
  end

  describe "the PWA" do
    setup do
      sw = Application.app_dir(:longx, "priv/static/sw.js")
      made? = not File.exists?(sw)
      if made?, do: File.write!(sw, "self.addEventListener('fetch', () => {});\n")
      on_exit(fn -> if made?, do: File.rm(sw) end)
      :ok
    end

    test "the service worker is served at the root (its scope is the whole page) and never kept as immutable",
         %{conn: conn} do
      sw = get(conn, "/sw.js")
      assert sw.status == 200
      assert [type] = get_resp_header(sw, "content-type")
      assert type =~ "javascript"
      refute Enum.any?(get_resp_header(sw, "cache-control"), &(&1 =~ "immutable"))
    end

    test "the manifest: an id, the language, the shortcuts, an open window reused" do
      manifest =
        :longx
        |> Application.app_dir("priv/static/manifest.webmanifest")
        |> File.read!()
        |> Jason.decode!()

      assert %{"id" => "/", "lang" => "zh-CN", "start_url" => "/", "display" => "standalone"} =
               manifest

      assert Enum.map(manifest["shortcuts"], & &1["url"]) == ["/new", "/settings/models"]
      assert manifest["launch_handler"] == %{"client_mode" => ["focus-existing", "auto"]}
      assert is_binary(manifest["description"])
    end
  end
end
