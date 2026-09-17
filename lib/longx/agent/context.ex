defmodule Longx.Agent.Context do
  @moduledoc """
  What a tool function gets besides its arguments: where it runs (`cwd`),
  which thread / turn / call it belongs to, and `emit` — a function the
  tool calls with output as it comes (`emit.(text)`), shown live in the
  UI as the row's output. Outside an agent (tests) `emit` may be nil.
  """

  @type t :: %__MODULE__{
          thread_id: String.t() | nil,
          turn_id: String.t() | nil,
          call_id: String.t() | nil,
          item_id: String.t() | nil,
          project_id: String.t() | nil,
          cwd: String.t() | nil,
          emit: (String.t() -> :ok) | nil
        }

  defstruct thread_id: nil,
            turn_id: nil,
            call_id: nil,
            item_id: nil,
            project_id: nil,
            cwd: nil,
            emit: nil

  @doc "Sends output to the UI as it happens; a no-op without an emitter."
  @spec emit(t | map, String.t()) :: :ok
  def emit(%{emit: emit}, text) when is_function(emit, 1) and is_binary(text), do: emit.(text)
  def emit(_context, _text), do: :ok

  @doc "Resolves a path a tool got against the working directory."
  @spec path(t | map, String.t()) :: String.t()
  def path(%{cwd: cwd}, path) when is_binary(cwd), do: Path.expand(path, cwd)
  def path(_context, path), do: Path.expand(path)
end
