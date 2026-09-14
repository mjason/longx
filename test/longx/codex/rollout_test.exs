defmodule Longx.Codex.RolloutTest do
  # codex's on-disk record of a thread (sessions/**/rollout-*.jsonl), read
  # without a codex process — what the memory pipeline learns from
  use ExUnit.Case, async: true

  alias Longx.Codex.Rollout

  setup do
    home = Path.join(System.tmp_dir!(), "longx-rollout-#{System.unique_integer([:positive])}")
    day = Path.join(home, "sessions/2026/09/14")
    File.mkdir_p!(day)
    on_exit(fn -> File.rm_rf!(home) end)

    lines = [
      %{
        type: "session_meta",
        payload: %{id: "thr_1", cwd: "/p", timestamp: "2026-09-14T04:48:15.522Z"}
      },
      %{
        type: "response_item",
        payload: %{
          type: "message",
          role: "developer",
          content: [%{type: "input_text", text: "## Longx 全局记忆 …"}]
        }
      },
      %{
        type: "response_item",
        payload: %{
          type: "message",
          role: "user",
          content: [
            %{
              type: "input_text",
              text: "<environment_context>\n  <cwd>/p</cwd>\n</environment_context>"
            }
          ]
        }
      },
      %{
        type: "response_item",
        payload: %{type: "message", role: "user", content: [%{type: "input_text", text: "把测试跑绿"}]}
      },
      %{type: "response_item", payload: %{type: "reasoning", summary: []}},
      %{
        type: "response_item",
        payload: %{
          type: "function_call",
          name: "exec_command",
          arguments: ~s({"cmd":"mix test"}),
          call_id: "c1"
        }
      },
      %{
        type: "response_item",
        payload: %{type: "function_call_output", call_id: "c1", output: "12 tests, 0 failures"}
      },
      %{
        type: "response_item",
        payload: %{
          type: "message",
          role: "assistant",
          content: [%{type: "output_text", text: "全绿了。"}]
        }
      },
      %{type: "event_msg", payload: %{type: "task_complete"}}
    ]

    path = Path.join(day, "rollout-2026-09-14T12-48-15-thr_1.jsonl")
    File.write!(path, Enum.map_join(lines, "", &(Jason.encode!(&1) <> "\n")))
    File.write!(Path.join(day, "rollout-2026-09-14T13-00-00-thr_2.jsonl"), "not json\n")
    %{home: home, path: path}
  end

  test "find/2 locates a thread's rollout by id", %{home: home, path: path} do
    assert {:ok, ^path} = Rollout.find(home, "thr_1")
    assert :error = Rollout.find(home, "thr_nobody")
  end

  test "transcript/1: the user's and the assistant's words, and what was run — not the instructions, not the environment",
       %{path: path} do
    assert {:ok, transcript} = Rollout.transcript(path)

    assert transcript == [
             {:user, "把测试跑绿"},
             {:command, "mix test"},
             {:assistant, "全绿了。"}
           ]
  end

  test "as_text/2 renders a transcript for a prompt, capped from the front", %{path: path} do
    {:ok, transcript} = Rollout.transcript(path)
    text = Rollout.as_text(transcript)
    assert text == "用户：把测试跑绿\n$ mix test\n助手：全绿了。"
    assert String.length(Rollout.as_text(transcript, 12)) <= 13
  end

  test "a broken file is an error, not a crash", %{home: home} do
    {:ok, path} = Rollout.find(home, "thr_2")
    assert {:ok, []} = Rollout.transcript(path)
  end
end
