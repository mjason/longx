defmodule LongxWeb.ExtensionControllerTest do
  use LongxWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:longx, Longx.Chrome, [])
    dir = Path.join(System.tmp_dir!(), "longx-ext-#{System.unique_integer([:positive])}")
    Application.put_env(:longx, Longx.Chrome, Keyword.put(previous, :extension_dir, dir))

    on_exit(fn ->
      Application.put_env(:longx, Longx.Chrome, previous)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "without a build the download says how to make one", %{conn: conn} do
    conn = get(conn, "/extension/longx-chrome.zip")
    assert conn.status == 404
    assert conn.resp_body =~ "mix assets.build"

    assert %{built: false, version: nil, url: "/extension/longx-chrome.zip"} =
             Longx.Chrome.extension_info()
  end

  test "the built extension is zipped whole, named after its version", %{conn: conn, dir: dir} do
    File.mkdir_p!(Path.join(dir, "icons"))

    File.write!(
      Path.join(dir, "manifest.json"),
      ~s({"manifest_version": 3, "name": "Longx", "version": "0.1.0"})
    )

    File.write!(Path.join(dir, "background.js"), "// sw")
    File.write!(Path.join(dir, "icons/icon-16.png"), <<137, 80, 78, 71>>)

    conn = get(conn, "/extension/longx-chrome.zip")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/zip"

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="longx-chrome-0.1.0.zip")
           ]

    {:ok, entries} = :zip.list_dir(conn.resp_body)
    names = for {:zip_file, name, _, _, _, _} <- entries, do: to_string(name)
    assert Enum.sort(names) == ["background.js", "icons/icon-16.png", "manifest.json"]
    assert %{built: true, version: "0.1.0"} = Longx.Chrome.extension_info()
  end
end
