defmodule Longx.Exec.PathUriTest do
  use ExUnit.Case, async: true

  alias Longx.Exec.PathUri

  describe "to_path/1" do
    test "decodes a plain file URI" do
      assert PathUri.to_path("file:///home/mj/dev") == {:ok, "/home/mj/dev"}
    end

    test "percent-decodes UTF-8 segments (CJK project names)" do
      assert PathUri.to_path("file:///home/mj/%E6%95%B0%E5%AD%A6%E7%B2%BE%E7%81%B5/a%20b") ==
               {:ok, "/home/mj/数学精灵/a b"}
    end

    test "the root" do
      assert PathUri.to_path("file:///") == {:ok, "/"}
    end

    test "refuses other schemes, authorities and relative paths" do
      assert {:error, _} = PathUri.to_path("http://x/y")
      assert {:error, _} = PathUri.to_path("file://server/share")
      assert {:error, _} = PathUri.to_path("/plain/path")
      assert {:error, _} = PathUri.to_path(nil)
    end
  end

  describe "from_path/1" do
    test "encodes what needs encoding and nothing else" do
      assert PathUri.from_path("/home/mj/数学精灵/a b#c?d%") ==
               "file:///home/mj/%E6%95%B0%E5%AD%A6%E7%B2%BE%E7%81%B5/a%20b%23c%3Fd%25"

      assert PathUri.from_path("/home/mj/dev-1_2.x~") == "file:///home/mj/dev-1_2.x~"
    end

    test "round-trips" do
      for path <- ["/", "/tmp", "/home/mj/数学精灵/α β/ü"] do
        assert PathUri.to_path(PathUri.from_path(path)) == {:ok, path}
      end
    end
  end
end
