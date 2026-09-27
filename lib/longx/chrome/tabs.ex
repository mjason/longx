defmodule Longx.Chrome.Tabs do
  @moduledoc """
  Who holds which tab: every tab a session owns is registered under its
  project and its browser (`Longx.Chrome.TabRegistry`, duplicate keys; a
  session's death releases them), so a project's `max_tabs` counts all its
  sessions together and a browser's `max_tabs` counts every project.
  """

  @registry Longx.Chrome.TabRegistry

  @spec claim(String.t(), String.t(), integer, String.t(), String.t()) :: :ok
  def claim(project_id, browser_id, tab_id, thread_id, title) do
    value = %{tab_id: tab_id, thread_id: thread_id, title: title}
    {:ok, _} = Registry.register(@registry, {:project, project_id}, value)
    {:ok, _} = Registry.register(@registry, {:browser, browser_id}, value)
    :ok
  end

  @spec release(String.t(), String.t(), integer) :: :ok
  def release(project_id, browser_id, tab_id) do
    # a map pattern matches the entries whose value has these keys (the caller's own)
    Registry.unregister_match(@registry, {:project, project_id}, %{tab_id: tab_id})
    Registry.unregister_match(@registry, {:browser, browser_id}, %{tab_id: tab_id})
    :ok
  end

  @spec of_project(String.t()) :: non_neg_integer
  def of_project(project_id), do: Registry.count_match(@registry, {:project, project_id}, :_)

  @doc "Tabs held in a browser, by session: `[%{thread_id, title, tabs}]`."
  @spec of_browser(String.t()) :: [
          %{thread_id: String.t(), title: String.t(), tabs: non_neg_integer}
        ]
  def of_browser(browser_id) do
    Registry.lookup(@registry, {:browser, browser_id})
    |> Enum.group_by(fn {_pid, v} -> {v.thread_id, v.title} end)
    |> Enum.map(fn {{thread_id, title}, entries} ->
      %{thread_id: thread_id, title: title, tabs: length(entries)}
    end)
    |> Enum.sort_by(& &1.title)
  end

  @spec count_of_browser(String.t()) :: non_neg_integer
  def count_of_browser(browser_id),
    do: Registry.count_match(@registry, {:browser, browser_id}, :_)
end
