defmodule Longx.Codex.Tool.Context do
  @moduledoc """
  What a tool knows about the call it is serving — the `Plug.Conn` of tool
  calls. Built by `Longx.Codex.Tool.Runner` from codex's `item/tool/call`
  params and the thread's `Longx.Codex.ThreadState`.

    * `snapshot` is a zero-arity function: reading the thread view is an ETS
      scan, so it is only paid by tools that ask for it
    * `project` is reserved for the thread ↔ project mapping to come
    * `assigns` is free space for forks (a per-tool pipeline can put things there)
  """

  defstruct thread_id: nil,
            turn_id: nil,
            call_id: nil,
            cwd: nil,
            snapshot: nil,
            project: nil,
            assigns: %{}

  @type t :: %__MODULE__{
          thread_id: String.t() | nil,
          turn_id: String.t() | nil,
          call_id: String.t() | nil,
          cwd: Path.t() | nil,
          snapshot: (-> Longx.Codex.ThreadState.snapshot()) | nil,
          project: term,
          assigns: map
        }
end
