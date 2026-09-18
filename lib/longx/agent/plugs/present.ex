defmodule Longx.Agent.Plugs.Present do
  @moduledoc """
  Cards for the person: `present` draws a generative UI tree — a table, a
  row of facts, a chart, a form — from assistant-ui's component vocabulary
  (`@assistant-ui/react-generative-ui`), and `prompt_user` draws one and
  waits for what the person fires in it (a choice, a form). The schema of
  both is `priv/agent/present.json`, generated from the same library the
  client renders with (`npm run present-schema` in `assets/`, checked by
  `mix precommit`), so the model can only name what the page can draw.

  The tree is the call's arguments; the item the person sees is the
  `longx.present` / `longx.prompt_user` tool call itself, and the model
  reads only "shown to the user" (or the person's answer). A plug's own
  code pushes a card without the model through `Longx.Agent.Context.present/2`.
  """

  use Longx.Agent.Plug

  @schema_path Path.join(:code.priv_dir(:longx), "agent/present.json")
  @external_resource @schema_path
  @vocabulary Jason.decode!(File.read!(@schema_path))

  @ask_timeout 600_000

  instructions """
  # Cards for the person

  `present` draws a card in the conversation from a fixed component vocabulary (`$type`: Card, Row, Col, Fact, Table, Chart, Markdown, Alert, Badge, ListView, Image, …; nest with `children`). Use it when a structure says it better than prose: a comparison or any tabular data (Table), a few key numbers (Facts in a Row), a trend (Chart), a status or warning (Alert), code or a longer formatted passage (Markdown, with fenced code). Keep trees small and say the conclusion in words as well — the card is not a substitute for the answer. Plain conversation, short lists and file contents stay prose.

  `prompt_user` draws a card the person acts on and waits for the answer: a choice (Buttons with `$action`, a Select, a RadioGroup), a form (a Card with `asForm` and `confirm`, or a Form) — use it when you need a decision or values from the person before going on; the result is what they fired (`type` of the `$action`, `$input` with the value or the form's values). Do not use it for yes / no questions you can simply ask in text.
  """

  tool :present, @vocabulary["present"]["description"],
    namespace: "longx",
    schema: @vocabulary["present"]["parameters"] do
  end

  tool :prompt_user, @vocabulary["prompt_user"]["description"],
    namespace: "longx",
    schema: @vocabulary["prompt_user"]["parameters"],
    timeout: @ask_timeout + 5_000 do
  end

  @doc "The component names the vocabulary offers."
  @spec components() :: [String.t()]
  def components, do: @vocabulary["components"]

  def present(_tree, _ctx), do: {:ok, "shown to the user"}

  def prompt_user(tree, ctx) do
    case Context.ask(ctx, title: title_of(tree), spec: tree, timeout: @ask_timeout) do
      {:ok, %{"action" => action}} -> {:ok, Jason.encode!(action)}
      {:ok, answer} -> {:ok, Jason.encode!(answer)}
      {:error, :cancelled} -> {:error, "the person dismissed it without answering"}
      {:error, :timeout} -> {:error, "no answer from the person within the time"}
      {:error, :no_agent} -> {:error, "no agent to ask the person through"}
    end
  end

  defp title_of(%{"title" => title}) when is_binary(title) and title != "", do: title
  defp title_of(_tree), do: "需要你选择"
end
