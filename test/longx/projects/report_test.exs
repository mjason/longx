defmodule Longx.Projects.ReportTest do
  # A conversation as JSON for another agent to look into (GET /api/p/<slug>/t/<id>):
  # the thread, its turns with what the page shows in each, long text trimmed
  # to its start and end unless asked in full — read without waking anything.
  use Longx.DataCase, async: false

  alias Longx.Agent.Transcript
  alias Longx.Projects
  alias Longx.Projects.Report

  setup do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "longx-report-#{n}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, project} = Projects.create_project(%{name: "Report #{n}", root_path: root})
    kid = "native_report_#{n}"

    {:ok, thread} =
      Projects.create_thread(%{
        kernel_thread_id: kid,
        project_id: project.id,
        cwd: root,
        title: "look around"
      })

    now = DateTime.utc_now()
    long = String.duplicate("x", 10_000)

    for {turn, text, extra} <- [
          {"turn_a", "list files",
           [
             %{
               "id" => "c1",
               "type" => "commandExecution",
               "command" => "ls",
               "status" => "inProgress"
             },
             %{
               "id" => "c1",
               "type" => "commandExecution",
               "command" => "ls",
               "status" => "completed",
               "exitCode" => 0,
               "aggregatedOutput" => long
             },
             %{"id" => "m1", "type" => "agentMessage", "text" => "many files"}
           ]},
          {"turn_b", "and now?", [%{"id" => "m2", "type" => "agentMessage", "text" => "done"}]}
        ] do
      {:ok, row} =
        Projects.create_turn(%{
          kernel_turn_id: turn,
          thread_id: thread.id,
          user_text: text,
          started_at: now
        })

      {:ok, _} = Projects.complete_turn(row, %{status: :completed, completed_at: now})

      user = %{
        "id" => "u-" <> turn,
        "type" => "userMessage",
        "turnId" => turn,
        "content" => [%{"type" => "text", "text" => text}]
      }

      for {ui, i} <- Enum.with_index([user | extra]) do
        Transcript.append!(%{
          thread_id: kid,
          turn_id: turn,
          seq: if(turn == "turn_a", do: i + 1, else: i + 10),
          kind: :activity,
          input: %{},
          ui: Map.put(ui, "turnId", turn)
        })
      end
    end

    %{project: project, thread: thread, kid: kid}
  end

  test "a thread: its state and its turns with what each shows, long text trimmed; in full on request",
       %{project: project, thread: thread, kid: kid} do
    assert {:ok, report} = Report.thread(project.slug, thread.id, base: "http://box:7788")

    assert %{"id" => id, "kernelThreadId" => ^kid, "title" => "look around"} = report["thread"]
    assert id == thread.id
    assert report["page"] == "http://box:7788/p/#{project.slug}/t/#{thread.id}"
    assert report["api"] == "http://box:7788/api/p/#{project.slug}/t/#{thread.id}"
    assert %{"total" => 2, "shown" => 2, "list" => [a, b]} = report["turns"]

    assert %{"kernelTurnId" => "turn_a", "status" => "completed", "userText" => "list files"} = a
    # the command once, as it ended (started and completed are one item)
    assert [
             %{"type" => "userMessage"},
             %{"type" => "commandExecution", "status" => "completed"} = cmd,
             %{"text" => "many files"}
           ] =
             a["items"]

    assert String.length(cmd["aggregatedOutput"]) < 3_000
    assert cmd["aggregatedOutput"] =~ "omitted"
    assert %{"kernelTurnId" => "turn_b", "items" => [_, %{"text" => "done"}]} = b

    {:ok, full} = Report.thread(project.slug, thread.id, full: true)
    [a_full, _] = full["turns"]["list"]
    assert Enum.at(a_full["items"], 1)["aggregatedOutput"] == String.duplicate("x", 10_000)
  end

  test "the last turns only on request; the kernel id finds the thread too; another project's slug does not",
       %{project: project, thread: thread, kid: kid} do
    assert {:ok,
            %{"turns" => %{"total" => 2, "shown" => 1, "list" => [%{"kernelTurnId" => "turn_b"}]}}} =
             Report.thread(project.slug, kid, turns: 1)

    assert {:error, :not_found} = Report.thread("no-such-project", thread.id)
    assert {:error, :not_found} = Report.thread(project.slug, Ash.UUID.generate())
  end

  test "a project: its conversations, each with the address of its own report", %{
    project: project,
    thread: thread
  } do
    assert {:ok, %{"project" => %{"slug" => slug}, "threads" => [row]}} =
             Report.project(project.slug, base: "http://box:7788")

    assert slug == project.slug
    assert row["id"] == thread.id
    assert row["api"] == "http://box:7788/api/p/#{project.slug}/t/#{thread.id}"
    assert {:error, :not_found} = Report.project("no-such-project")
  end
end
