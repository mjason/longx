defmodule Longx.System.PublicUrlTest do
  use Longx.DataCase, async: false

  alias Longx.System

  setup do
    Ash.bulk_destroy!(System.Setting, :destroy, %{}, authorize?: false)
    LongxWeb.Origins.forget()
    on_exit(fn -> LongxWeb.Origins.forget() end)
    :ok
  end

  test "the address the outside reaches Longx at: the setting, else where the last browser came from, else the endpoint" do
    assert System.public_url() == LongxWeb.Endpoint.url()

    LongxWeb.Origins.remember(%URI{scheme: "http", host: "192.168.2.129", port: 7788})
    assert System.public_url() == "http://192.168.2.129:7788"

    assert {:ok, "https://longx.example"} = System.set_public_url("https://longx.example/")
    assert System.public_url() == "https://longx.example"
    assert {:error, _} = System.set_public_url("not a url")
    assert {:ok, nil} = System.set_public_url("")
    assert System.public_url() == "http://192.168.2.129:7788"
  end
end
