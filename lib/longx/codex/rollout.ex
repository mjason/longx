defmodule Longx.Codex.Rollout do
  @moduledoc """
  Codex's own record of a thread: `sessions/YYYY/MM/DD/rollout-<stamp>-<id>.jsonl`
  under a `CODEX_HOME`, one JSON line per event. Read here without a codex
  process, for the memory pipeline (`Longx.Memory.Extract`) — what the
  person said, what the model answered, what was run; not the developer
  instructions, not the environment block codex prepends.
  """

  @type entry :: {:user | :assistant, String.t()} | {:command, String.t()}

  @doc "The rollout file of a thread, by codex thread id."
  @spec find(Path.t(), String.t()) :: {:ok, Path.t()} | :error
  def find(home, codex_thread_id) do
    home
    |> Path.join("sessions/**/rollout-*-#{codex_thread_id}.jsonl")
    |> Path.wildcard()
    |> Enum.sort()
    |> List.last()
    |> case do
      nil -> :error
      path -> {:ok, path}
    end
  end

  @doc "The conversation in order: user and assistant messages, commands run."
  @spec transcript(Path.t()) :: {:ok, [entry]} | {:error, term}
  def transcript(path) do
    with {:ok, raw} <- File.read(path) do
      entries =
        raw
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, %{"type" => "response_item", "payload" => payload}} -> entry(payload)
            _ -> []
          end
        end)

      {:ok, entries}
    end
  end

  defp entry(%{"type" => "message", "role" => "user", "content" => content}) do
    text = text_of(content, "input_text")

    if String.starts_with?(text, "<environment_context>") or text == "",
      do: [],
      else: [{:user, text}]
  end

  defp entry(%{"type" => "message", "role" => "assistant", "content" => content}) do
    case text_of(content, "output_text") do
      "" -> []
      text -> [{:assistant, text}]
    end
  end

  defp entry(%{"type" => "function_call", "name" => "exec_command", "arguments" => args}) do
    case Jason.decode(args) do
      {:ok, %{"cmd" => cmd}} when is_binary(cmd) -> [{:command, cmd}]
      _ -> []
    end
  end

  defp entry(_), do: []

  defp text_of(content, type) when is_list(content) do
    for %{"type" => ^type, "text" => text} <- content, into: "", do: text
  end

  defp text_of(_, _), do: ""

  @doc "The transcript as prompt text (`用户：` / `助手：` / `$ cmd`), at most `max` characters."
  @spec as_text([entry], pos_integer) :: String.t()
  def as_text(transcript, max \\ 60_000) do
    text =
      Enum.map_join(transcript, "\n", fn
        {:user, t} -> "用户：" <> t
        {:assistant, t} -> "助手：" <> t
        {:command, c} -> "$ " <> c
      end)

    if String.length(text) <= max, do: text, else: String.slice(text, 0, max) <> "…"
  end
end
