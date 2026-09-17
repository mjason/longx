defmodule Longx.Agent.KnowledgeTest do
  # the global root is configuration: not async
  use ExUnit.Case, async: false

  alias Longx.Agent.{Context, Knowledge, Step, Tool}
  alias Longx.Agent.Plugs.Knowledge, as: Plug

  setup do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "longx-know-#{n}")
    global = Path.join(System.tmp_dir!(), "longx-know-global-#{n}")
    File.mkdir_p!(Path.join(root, ".longx/knowledge/ops"))
    previous = Application.get_env(:longx, Longx.Agent.Loader, [])
    Application.put_env(:longx, Longx.Agent.Loader, Keyword.put(previous, :global_dir, global))

    on_exit(fn ->
      Application.put_env(:longx, Longx.Agent.Loader, previous)
      File.rm_rf!(root)
      File.rm_rf!(global)
    end)

    File.write!(Path.join(root, ".longx/knowledge/rules.md"), """
    ---
    title: House rules
    summary: What always holds in this repo
    always: true
    ---
    Run mix test after every change.
    """)

    File.write!(Path.join(root, ".longx/knowledge/ops/deploy.md"), """
    ---
    title: Deploying to staging
    summary: deploy.sh, never kubectl by hand
    tags: [deploy, ops]
    ---
    Use ./deploy.sh staging. Prod needs a smoke test first.
    """)

    File.write!(
      Path.join(root, ".longx/knowledge/plain.md"),
      "No front matter here.\nSecond line.\n"
    )

    %{root: root, global: global, ctx: %Context{cwd: root}}
  end

  defp tool!(name),
    do: Enum.find(Plug.__agent_tools__(), &(&1.name == name)) || flunk("no tool #{name}")

  test "docs are read from the three roots with their front matter; the shipped root is there", %{
    root: root
  } do
    docs = Knowledge.docs(root)
    paths = Enum.map(docs, & &1.path)
    assert "project/rules.md" in paths
    assert "project/ops/deploy.md" in paths
    assert "project/plain.md" in paths
    assert "longx/writing-plugs.md" in paths

    rules = Enum.find(docs, &(&1.path == "project/rules.md"))

    assert %{
             title: "House rules",
             summary: "What always holds in this repo",
             always?: true,
             body: "Run mix test after every change.\n"
           } = rules

    deploy = Enum.find(docs, &(&1.path == "project/ops/deploy.md"))
    assert deploy.tags == ["deploy", "ops"]
    refute deploy.always?

    plain = Enum.find(docs, &(&1.path == "project/plain.md"))
    assert %{title: "plain", summary: "No front matter here."} = plain
  end

  test "the plug: always-docs in the prompt, the rest as an index, three tools", %{root: root} do
    step = Plug.call(Step.new(cwd: root, phase: :request), Plug.init([]))
    text = Enum.join(step.instructions, "\n")

    assert text =~ "Run mix test after every change."
    assert text =~ "project/ops/ (1 doc) — Deploying to staging"
    assert text =~ "deploy.sh, never kubectl by hand"
    refute text =~ "Use ./deploy.sh staging"
    assert text =~ "longx/writing-plugs.md"

    assert Map.keys(step.tools) |> Enum.sort() == [
             "knowledge_read",
             "knowledge_search",
             "knowledge_write"
           ]

    assert Plug.call(Step.new(cwd: root, phase: :response), Plug.init([])).tools == %{}
  end

  test "always-docs and the index are capped, with a note", %{root: root} do
    for i <- 1..5 do
      File.write!(
        Path.join(root, ".longx/knowledge/big#{i}.md"),
        "---\ntitle: Big #{i}\nsummary: big\nalways: true\n---\n" <>
          String.duplicate("x", 5_000) <> "\n"
      )
    end

    step =
      Plug.call(Step.new(cwd: root, phase: :request), Plug.init(always_cap: 12_000, index_cap: 2))

    text = Enum.join(step.instructions, "\n")
    assert text =~ "omitted"
    assert text =~ "knowledge_search"
    assert byte_size(text) < 40_000
  end

  test "read, search, write; the shipped root is read-only; a write needs front matter", %{
    root: root,
    ctx: ctx,
    global: global
  } do
    assert {:ok, body} =
             Tool.call(tool!("knowledge_read"), %{"path" => "project/ops/deploy.md"}, ctx)

    assert body =~ "Use ./deploy.sh staging"
    assert {:error, msg} = Tool.call(tool!("knowledge_read"), %{"path" => "project/nope.md"}, ctx)
    assert msg =~ "nope.md"

    assert {:ok, hits} = Tool.call(tool!("knowledge_search"), %{"query" => "smoke test"}, ctx)
    assert hits =~ "project/ops/deploy.md"
    assert hits =~ "Prod needs a smoke test first."
    assert {:ok, "nothing" <> _} = Tool.call(tool!("knowledge_search"), %{"query" => "zzzz"}, ctx)

    content =
      "---\ntitle: Test data\nsummary: where the fixtures live\n---\nFixtures are under test/fixtures.\n"

    assert {:ok, written} =
             Tool.call(
               tool!("knowledge_write"),
               %{"path" => "project/testing/data.md", "content" => content},
               ctx
             )

    assert written =~ ".longx/shared/knowledge/testing/data.md"
    assert File.read!(Path.join(root, ".longx/shared/knowledge/testing/data.md")) == content

    assert {:ok, "Fixtures are under test/fixtures.\n"} =
             Tool.call(tool!("knowledge_read"), %{"path" => "project/testing/data.md"}, ctx)

    assert {:error, msg} =
             Tool.call(
               tool!("knowledge_write"),
               %{"path" => "project/ops/x.md", "content" => "no front matter"},
               ctx
             )

    assert msg =~ "front matter"

    assert {:error, msg} =
             Tool.call(
               tool!("knowledge_write"),
               %{"path" => "longx/x.md", "content" => content},
               ctx
             )

    assert msg =~ "read-only"

    assert {:error, _} =
             Tool.call(
               tool!("knowledge_write"),
               %{"path" => "project/../escape.md", "content" => content},
               ctx
             )

    # the global root is a repository of its own: every write a commit
    assert {:ok, _} =
             Tool.call(
               tool!("knowledge_write"),
               %{"path" => "global/me/profile.md", "content" => content},
               ctx
             )

    assert {:ok, _} =
             Tool.call(
               tool!("knowledge_write"),
               %{"path" => "global/me/profile.md", "content" => content <> "more\n"},
               ctx
             )

    assert File.exists?(Path.join(global, "knowledge/me/profile.md"))
    assert length(Longx.Git.log(Path.join(global, "knowledge"), limit: 10)) == 2
    assert "global/me/profile.md" in Enum.map(Knowledge.docs(root), & &1.path)
  end

  @doc_a "---\ntitle: Deploy steps\nsummary: how to deploy\n---\nStep one.\n"
  @doc_b "---\ntitle: Rollback\nsummary: how to roll back\n---\nStep back.\n"

  test "two levels: a doc needs a topic, a topic reads as its list, the index folds topics, local is a root of its own",
       %{root: root, ctx: ctx} do
    # a top-level file is refused with the rule
    assert {:error, msg} = Knowledge.write(root, "local/notes.md", @doc_a)
    assert msg =~ "topic"
    assert {:error, msg} = Knowledge.write(root, "project/notes.md", @doc_a)
    assert msg =~ "topic"

    assert {:ok, _} = Knowledge.write(root, "local/deploy/steps.md", @doc_a)
    assert {:ok, _} = Knowledge.write(root, "local/deploy/rollback.md", @doc_b)
    assert File.exists?(Path.join(root, ".longx/local/knowledge/deploy/steps.md"))

    # a write into local/ keeps it out of git
    assert File.read!(Path.join(root, ".gitignore")) =~ ".longx/local/"
    assert {:ok, _} = Knowledge.write(root, "local/deploy/steps.md", @doc_a <> "again\n")
    assert length(String.split(File.read!(Path.join(root, ".gitignore")), ".longx/local/")) == 2

    # a topic reads as its docs, one line each; a README speaks for the topic in the index
    assert {:ok, listing} = Knowledge.read(root, "local/deploy")
    assert listing =~ "local/deploy/steps.md — Deploy steps: how to deploy"
    assert listing =~ "local/deploy/rollback.md — Rollback: how to roll back"

    File.write!(
      Path.join(root, ".longx/local/knowledge/deploy/README.md"),
      "---\ntitle: Deploy\nsummary: everything about shipping\n---\n"
    )

    step = Plug.call(Step.new(phase: :request, cwd: root), Plug.init([]))
    index = Enum.join(step.instructions, "\n")
    assert index =~ "local/deploy/ (2 docs) — Deploy: everything about shipping"
    refute index =~ "local/deploy/steps.md"
    # the flat docs of before are still listed one by one; a topic of the shared tree folds too
    assert index =~ "project/plain.md"
    assert index =~ "project/ops/ (1 doc)"
    assert step.instructions |> Enum.join("\n") =~ "local/<topic>/<name>.md"

    # search finds inside a topic; the tool reads a topic too
    assert [%{path: "local/deploy/rollback.md"} | _] = Knowledge.search(root, "roll back")
    assert {:ok, text} = Tool.call(tool!("knowledge_read"), %{"path" => "local/deploy"}, ctx)
    assert text =~ "rollback.md"

    # promotion moves a local doc into the shared tree
    assert {:ok, "project/deploy/steps.md"} = Knowledge.promote(root, "local/deploy/steps.md")
    assert File.exists?(Path.join(root, ".longx/shared/knowledge/deploy/steps.md"))
    refute File.exists?(Path.join(root, ".longx/local/knowledge/deploy/steps.md"))
    assert {:error, _} = Knowledge.promote(root, "project/deploy/steps.md")
  end
end
