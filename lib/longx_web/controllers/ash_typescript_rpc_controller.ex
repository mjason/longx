defmodule LongxWeb.AshTypescriptRpcController do
  use LongxWeb, :controller

  def run(conn, params) do
    result = AshTypescript.Rpc.run_action(:longx, conn, params)
    json(conn, result)
  end

  def validate(conn, params) do
    result = AshTypescript.Rpc.validate_action(:longx, conn, params)
    json(conn, result)
  end
end
