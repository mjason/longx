defmodule Longx.Memory.Extract do
  @moduledoc """
  Idle threads → notes in the global memory. A thread that has been quiet
  for `idle_hours` (default 1) and has not been read since its last
  activity is read from codex's rollout on disk (`Longx.Codex.Rollout`, no
  codex process needed), the transcript goes to the default model with a
  prompt asking for durable, cross-project facts about the person, and each
  fact becomes a note (`source: auto`, with the project and thread). The
  thread is then marked (`Thread.memory_extracted_at`) — also when nothing
  was worth keeping, so it is never read twice. A model failure leaves it
  for the next run.
  """

  require Ash.Query
  require Logger

  alias Longx.Codex.{Pool, Rollout}
  alias Longx.Memory
  alias Longx.Projects
  alias Longx.Projects.Thread

  @prompt """
  你在为一个跨项目的 agent 工作台整理"全局记忆"。下面是用户和 agent 在某个项目里的一段对话。
  从中提炼**以后在别的项目里也用得上**的、关于这个用户的持久事实：偏好、习惯、工具选择、
  编码/提交/沟通风格、明确说过"以后都要 / 别再"的决定。不要项目内部的细节（某个文件、
  某个 bug、本次任务的进度），不要显而易见或只此一次的事，不要任何密钥、令牌、密码。

  只输出一个 JSON 数组，每项一句话（用对话的语言），一句一件事；没有值得记的就输出 []。
  """

  @doc "Threads due for extraction, oldest activity first, at most `limit` (default 2)."
  @spec candidates(keyword) :: [Thread.t()]
  def candidates(opts \\ []) do
    idle_hours = Keyword.get(opts, :idle_hours, 1)
    limit = Keyword.get(opts, :limit, 2)
    cutoff = DateTime.add(DateTime.utc_now(), -idle_hours * 3600, :second)

    Thread
    |> Ash.Query.filter(
      is_nil(parent_thread_id) and not is_nil(last_activity_at) and last_activity_at < ^cutoff and
        (is_nil(memory_extracted_at) or memory_extracted_at < last_activity_at) and
        status in [:idle, :archived, :unrecoverable] and project.global_memory == true
    )
    |> Ash.Query.sort(last_activity_at: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.load(:project)
    |> Ash.read!()
  end

  @doc "Distils one thread; `complete:` is the model call (default `Longx.AI.complete/3`). Answers with how many notes were written."
  @spec run(Thread.t(), keyword) :: {:ok, non_neg_integer} | {:error, term}
  def run(%Thread{} = thread, opts \\ []) do
    complete = Keyword.get(opts, :complete, &Longx.AI.complete/3)
    dir = Keyword.get(opts, :dir, Memory.dir())
    thread = Ash.load!(thread, :project)

    case transcript(thread) do
      "" ->
        mark(thread)
        {:ok, 0}

      text ->
        with {:ok, answer} <- complete.(@prompt, text, max_output_tokens: 2048),
             {:ok, facts} <- facts(answer) do
          for fact <- facts do
            {:ok, _} =
              Memory.add_note(dir, fact,
                project: thread.project.name,
                thread: thread.codex_thread_id,
                source: "auto"
              )
          end

          mark(thread)
          {:ok, length(facts)}
        else
          {:error, reason} = error ->
            Logger.warning("memory extract #{thread.codex_thread_id}: #{inspect(reason)}")
            error
        end
    end
  end

  defp transcript(%Thread{project_id: project_id, codex_thread_id: id}) do
    with {:ok, path} <- Rollout.find(Pool.home_dir(project_id), id),
         {:ok, entries} <- Rollout.transcript(path),
         true <- Enum.any?(entries, &match?({:user, _}, &1)) do
      Rollout.as_text(entries)
    else
      _ -> ""
    end
  end

  # the model's JSON array of strings, fenced or not
  defp facts(answer) do
    json =
      case Regex.run(~r/```(?:json)?\s*(\[.*?\])\s*```/s, answer) do
        [_, inner] -> inner
        nil -> answer
      end

    case Jason.decode(String.trim(json)) do
      {:ok, list} when is_list(list) ->
        {:ok,
         list |> Enum.filter(&is_binary/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))}

      _ ->
        {:error, {:bad_answer, String.slice(answer, 0, 200)}}
    end
  end

  defp mark(thread) do
    {:ok, _} = Projects.mark_thread_extracted(thread)
    :ok
  end
end
