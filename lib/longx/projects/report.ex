defmodule Longx.Projects.Report do
  @moduledoc """
  A conversation as JSON for another agent to look into — the page's address
  with `/api` in front (`GET /api/p/<slug>/t/<id>`, `LongxWeb.ApiController`;
  `GET /api/p/<slug>` lists the project's conversations): the thread's row and
  live state (running turn, progress, goal, what waits, pending asks, jobs,
  the thread's recent model requests with their errors), its sub-agents with
  their own reports' addresses, and its turns — each row's status, error and
  usage with the items the page shows for it (commands and their output, file
  changes, tool calls, messages).

  Read without waking anything: the live view when the thread's agent has
  one (`ThreadState`), else the transcript's UI items (a started and a
  completed version of an item are one: the last wins). By default the last
  20 turns (`turns:` a number or `:all`) and every string past 2 000
  characters trimmed to its start and end (`full: true` keeps them whole).
  """

  alias Longx.Agent.{ThreadState, Transcript}
  alias Longx.Projects
  alias Longx.Projects.{Project, Thread}

  @default_turns 20
  @max_string 2_000
  @keep 900
  @requests 20

  @type opts :: [turns: pos_integer | :all, full: boolean, base: String.t()]

  @doc "A project's conversations (root threads, latest first), each with its report's address."
  @spec project(String.t(), opts) :: {:ok, map} | {:error, :not_found}
  def project(slug, opts \\ []) do
    with {:ok, project} <- project_by_slug(slug) do
      base = Keyword.get(opts, :base, "")

      threads =
        for t <- Projects.list_threads!(project) do
          %{
            "id" => t.id,
            "kernelThreadId" => t.kernel_thread_id,
            "title" => t.title,
            "preview" => t.preview,
            "status" => t.status,
            "handle" => t.handle,
            "lastActivityAt" => t.last_activity_at,
            "page" => page_url(base, project, t),
            "api" => api_url(base, project, t)
          }
        end

      {:ok, json_shaped(%{"project" => project_view(project), "threads" => threads})}
    end
  end

  @doc "One conversation: the thread, its live state, its sub-agents and its turns with their items."
  @spec thread(String.t(), String.t(), opts) :: {:ok, map} | {:error, :not_found}
  def thread(slug, id, opts \\ []) do
    with {:ok, project} <- project_by_slug(slug),
         {:ok, thread} <- thread_in(project, id) do
      base = Keyword.get(opts, :base, "")
      full? = Keyword.get(opts, :full, false)
      kid = thread.kernel_thread_id
      snapshot = ThreadState.snapshot(kid)
      turns = turns(thread, items(kid, snapshot), Keyword.get(opts, :turns, @default_turns))

      report = %{
        "page" => page_url(base, project, thread),
        "api" => api_url(base, project, thread),
        "project" => project_view(project),
        "thread" => thread_view(thread, base, project),
        "live" => live(kid, snapshot),
        "subagents" => subagents(thread, base, project),
        "jobs" => Longx.Jobs.list(kid),
        "modelRequests" => model_requests(kid),
        "turns" => turns
      }

      report = json_shaped(report)
      {:ok, if(full?, do: report, else: trim(report))}
    end
  end

  ## Lookups

  defp project_by_slug(slug) do
    case Projects.get_project_by_slug(slug) do
      {:ok, %Project{} = project} -> {:ok, project}
      _ -> {:error, :not_found}
    end
  end

  # the row id from the page's address, or the kernel's thread id
  defp thread_in(%Project{id: project_id}, id) do
    found =
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> Ash.get(Thread, uuid)
        :error -> Projects.get_thread_by_kernel_id(id)
      end

    case found do
      {:ok, %Thread{project_id: ^project_id} = thread} -> {:ok, thread}
      _ -> {:error, :not_found}
    end
  end

  ## Parts

  defp project_view(project),
    do: %{
      "id" => project.id,
      "slug" => project.slug,
      "name" => project.name,
      "rootPath" => project.root_path
    }

  defp thread_view(thread, base, project) do
    parent =
      with id when is_binary(id) <- thread.parent_thread_id,
           {:ok, row} <- Ash.get(Thread, id) do
        %{"id" => row.id, "api" => api_url(base, project, row)}
      else
        _ -> nil
      end

    %{
      "id" => thread.id,
      "kernelThreadId" => thread.kernel_thread_id,
      "title" => thread.title,
      "preview" => thread.preview,
      "status" => thread.status,
      "handle" => thread.handle,
      "onDuty" => thread.on_duty,
      "address" => Projects.agent_name(thread),
      "model" => thread.model_slug,
      "effort" => thread.reasoning_effort,
      "cwd" => thread.cwd,
      "agentPath" => thread.agent_path,
      "parent" => parent,
      "insertedAt" => thread.inserted_at,
      "lastActivityAt" => thread.last_activity_at
    }
  end

  defp live(kid, snapshot) do
    %{
      "agent" => if(Longx.Agent.whereis(kid), do: "alive", else: "asleep"),
      "running" =>
        case Projects.agent_status(kid) do
          {:running, turn_id} -> turn_id
          :idle -> nil
        end,
      "progress" => snapshot.progress,
      "goal" => snapshot.goal,
      "waiting" => snapshot.waiting,
      "pendingRequests" =>
        Enum.map(snapshot.pending_requests, &Map.take(&1, [:id, :method, :params])),
      "tokenUsage" => snapshot.token_usage
    }
  end

  defp subagents(thread, base, project) do
    case Projects.list_subagents(thread.id) do
      {:ok, rows} ->
        for row <- rows do
          %{
            "id" => row.id,
            "name" => row.agent_path,
            "status" => row.status,
            "model" => row.model_slug,
            "api" => api_url(base, project, row)
          }
        end

      _ ->
        []
    end
  end

  defp model_requests(kid) do
    Longx.AI.Gateway.Log.recent(1_000)
    |> Enum.filter(&(&1.thread_id == kid))
    |> Enum.take(@requests)
    |> Enum.map(&Map.drop(&1, [:started]))
  end

  # the page's view when the agent has one, else the transcript's UI items
  defp items(kid, %{thread: nil}) do
    kid
    |> Transcript.items!()
    |> Enum.map(& &1.ui)
    |> Enum.filter(&is_map/1)
    |> dedupe()
  end

  defp items(_kid, snapshot), do: snapshot.items

  # a started and a completed version of one item: one, where it first stood, as it last was
  defp dedupe(items) do
    last = Map.new(items, &{&1["id"], &1})

    items
    |> Enum.uniq_by(& &1["id"])
    |> Enum.map(&Map.fetch!(last, &1["id"]))
  end

  defp turns(thread, items, window) do
    rows = Projects.list_turns!(thread)
    by_turn = Enum.group_by(items, & &1["turnId"])
    row_of = Map.new(rows, &{&1.kernel_turn_id, &1})

    # the view's order, then any row with nothing in the view (a turn that failed at once)
    ids =
      items
      |> Enum.map(& &1["turnId"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> then(&(&1 ++ (Enum.map(rows, fn r -> r.kernel_turn_id end) -- &1)))

    shown = if window == :all, do: ids, else: Enum.take(ids, -window)

    list =
      for id <- shown do
        row = row_of[id]

        %{
          "kernelTurnId" => id,
          "id" => row && row.id,
          "status" => row && row.status,
          "userText" => row && row.user_text,
          "error" => row && row.error,
          "model" => row && row.model_slug,
          "effort" => row && row.reasoning_effort,
          "startedAt" => row && row.started_at,
          "completedAt" => row && row.completed_at,
          "usage" => row && row.usage,
          "items" => Map.get(by_turn, id, [])
        }
      end

    %{"total" => length(ids), "shown" => length(list), "list" => list}
  end

  ## Shape

  # what JSON will say, already: a status is a string, not an atom
  defp json_shaped(value) when is_boolean(value) or is_nil(value), do: value
  defp json_shaped(value) when is_atom(value), do: Atom.to_string(value)
  defp json_shaped(%DateTime{} = value), do: value
  defp json_shaped(%NaiveDateTime{} = value), do: value
  defp json_shaped(%_{} = value), do: value

  defp json_shaped(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), json_shaped(v)} end)

  defp json_shaped(value) when is_list(value), do: Enum.map(value, &json_shaped/1)
  defp json_shaped(value), do: value

  ## Trimming

  defp trim(value) when is_binary(value) do
    if String.length(value) > @max_string do
      omitted = String.length(value) - 2 * @keep

      String.slice(value, 0, @keep) <>
        "\n…[#{omitted} characters omitted — ?full=1 for all]…\n" <>
        String.slice(value, -@keep, @keep)
    else
      value
    end
  end

  defp trim(%DateTime{} = value), do: value
  defp trim(%_{} = value), do: value
  defp trim(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, trim(v)} end)
  defp trim(value) when is_list(value), do: Enum.map(value, &trim/1)
  defp trim(value), do: value

  ## Addresses

  defp page_url(base, project, thread), do: "#{base}/p/#{project.slug}/t/#{thread.id}"
  defp api_url(base, project, thread), do: "#{base}/api/p/#{project.slug}/t/#{thread.id}"
end
