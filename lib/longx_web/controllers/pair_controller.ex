defmodule LongxWeb.PairController do
  @moduledoc """
  `POST /pair` — the phone's one unauthenticated call: the code from
  Settings → 移动端 plus its name and platform, answered with the device
  token (shown once) and the server's version. Outside the CSRF pipeline:
  the phone has no session, and a wrong code is all an attacker gets.
  """

  use LongxWeb, :controller

  def create(conn, params) do
    attrs = %{
      name: String.slice(to_string(params["name"] || "手机"), 0, 80),
      platform: platform(params["platform"])
    }

    case Longx.System.pair_device(to_string(params["code"] || ""), attrs) do
      {:ok, %{device: device, token: token}} ->
        json(conn, %{
          token: token,
          device: %{id: device.id, name: device.name, platform: device.platform},
          server: %{version: to_string(Application.spec(:longx, :vsn))}
        })

      {:error, :invalid_code} ->
        conn |> put_status(401) |> json(%{error: "配对码不对或已过期"})

      {:error, _} ->
        conn |> put_status(422) |> json(%{error: "could not pair"})
    end
  end

  defp platform("android"), do: :android
  defp platform("ios"), do: :ios
  defp platform(_), do: :other
end
