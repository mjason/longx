defmodule Longx.Agent.Kernel.Compaction do
  @moduledoc false
  # The context fold (codex's shape): the summary request streamed like any model call, the transcript reloaded behind it.

  alias Longx.Agent.Transcript
  alias Longx.Agent.Kernel.State
  import Longx.Agent.Kernel.State
  @tasks Longx.Agent.TaskSupervisor

  @overflow ~r/context length|context_length|maximum context|too many tokens|token limit|exceeds .*context|prompt is too long|context window/i
  def overflow?(message), do: is_binary(message) and Regex.match?(@overflow, message)

  ## Compaction (the `compact` effect, `/compact`, an overflow): codex's shape

  @compact_prompt File.read!(Path.join(:code.priv_dir(:longx), "agent/compact/prompt.md"))
  @summary_prefix String.trim(
                    File.read!(
                      Path.join(:code.priv_dir(:longx), "agent/compact/summary_prefix.md")
                    )
                  )

  # a summary of the context so far, streamed from a task like any model call
  def start_compaction(%State{} = state, model) do
    ref = make_ref()

    request = %{
      "model" => model || "longx",
      "instructions" => @compact_prompt,
      "input" =>
        state.transcript ++
          [
            %{
              "type" => "message",
              "role" => "user",
              "content" => [%{"type" => "input_text", "text" => "Write the handoff summary now."}]
            }
          ],
      "tools" => [],
      "stream" => true,
      "store" => false,
      "client_metadata" => %{
        "thread_id" => state.thread_id,
        "turn_id" => state.turn_id,
        "x-codex-turn-metadata" => Jason.encode!(%{"request_kind" => "compaction"})
      }
    }

    task =
      Task.Supervisor.async_nolink(@tasks, Longx.Agent.Model, :run, [
        Longx.Agent.Model.prepare(request),
        self(),
        ref
      ])

    state = %{
      state
      | phase: :compacting,
        model_task: %{task: task, ref: ref},
        compacting: %{
          text: "",
          model: model || "longx",
          was_running: state.turn_id != nil,
          shown_at: System.monotonic_time(:millisecond)
        }
    }

    # the page is told at once: a fold between turns has no turn to spin for,
    # and one mid-turn read as a stall (nothing for a minute, then the marker)
    show_progress(state, 0)
  end

  @doc """
  Tells the thread the fold is running and how much of the summary is in
  (`turn/progress` of kind `compaction`, `turnId` nil between turns), or —
  with `nil` — that it is over.
  """
  def show_progress(%State{compacting: c} = state, bytes) when is_integer(bytes) do
    emit(state, "turn/progress", %{
      "turnId" => state.turn_id,
      "progress" => %{"kind" => "compaction", "name" => c.model, "bytes" => bytes}
    })

    state
  end

  def show_progress(%State{} = state, nil) do
    emit(state, "turn/progress", %{"turnId" => state.turn_id, "progress" => nil})
    state
  end

  # the summary's bytes as they stream: the first at once, then once a second
  def note_delta(%State{compacting: c} = state, delta) do
    text = c.text <> delta
    now = System.monotonic_time(:millisecond)
    state = %{state | compacting: %{c | text: text}}

    if c.text == "" or now - c.shown_at >= 1_000 do
      state
      |> show_progress(byte_size(text))
      |> then(&%{&1 | compacting: %{&1.compacting | shown_at: now}})
    else
      state
    end
  end

  def last_turn_id(%State{thread_id: id}) do
    case id |> Transcript.items!() |> List.last() do
      %{turn_id: turn_id} when is_binary(turn_id) -> turn_id
      _ -> "compaction"
    end
  end

  @doc "The summary is in: a `:compaction` item appended, the marker emitted, the context reloaded."
  def fold_summary(%State{} = state, c) do
    turn_id = state.turn_id || last_turn_id(state)
    summary = String.trim(c.text)

    input = %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => @summary_prefix <> "\n" <> summary}]
    }

    ui = %{"id" => new_id("item"), "type" => "contextCompaction", "turnId" => turn_id}
    seq = state.seq + 1

    Transcript.append!(%{
      thread_id: state.thread_id,
      turn_id: turn_id,
      seq: seq,
      kind: :compaction,
      input: input,
      ui: ui,
      model: c.model
    })

    emit(state, "item/completed", %{"item" => ui, "turnId" => turn_id})
    show_progress(state, nil)

    %{
      state
      | seq: seq,
        transcript: state.thread_id |> Transcript.items!() |> Transcript.input(),
        compacting: nil,
        model_task: nil,
        usage_last: nil,
        context_overflow: false,
        compact_requested: false
    }
  end
end
