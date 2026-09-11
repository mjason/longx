defmodule LongxWeb.ErrorJSONTest do
  use LongxWeb.ConnCase, async: true

  test "renders 404" do
    assert LongxWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert LongxWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
