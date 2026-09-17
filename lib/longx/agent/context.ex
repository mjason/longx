defmodule Longx.Agent.Context do
  @moduledoc """
  What a tool function gets besides its arguments: where it runs (`cwd`),
  which thread / turn / call it belongs to, and `emit` — a function the
  tool calls with output as it comes (`emit.(text)`), shown live in the
  UI as the row's output. Outside an agent (tests) `emit` may be nil.
  """

  @type t :: %__MODULE__{
          thread_id: String.t() | nil,
          turn_id: String.t() | nil,
          call_id: String.t() | nil,
          item_id: String.t() | nil,
          project_id: String.t() | nil,
          cwd: String.t() | nil,
          emit: (String.t() -> :ok) | nil,
          usage: %{last: map | nil, total: map},
          context_window: pos_integer | nil
        }

  defstruct thread_id: nil,
            turn_id: nil,
            call_id: nil,
            item_id: nil,
            project_id: nil,
            cwd: nil,
            emit: nil,
            usage: %{last: nil, total: %{}},
            context_window: nil

  @doc """
  Asks the person to do something and waits for them — a login, a code, a
  choice — from inside a tool. The request shows on the thread as a card
  (title, text, a link to open, fields to fill), the notify feed carries
  it, and the answer comes back here:

      Context.ask(ctx, title: "登录 COROS", text: "用存有训练数据的账号登录", url: "https://…")
      # => {:ok, %{"done" => true}} | {:ok, %{"code" => "…"}} (fields) | {:error, :cancelled | :timeout}

  With `callback: true` the kernel makes a URL a third party may send the
  browser back to (`<public url>/callback/<id>`); `url:` may then be a
  function of it (`fn callback -> "https://…?redirect_uri=" <> callback end`)
  and the answer is `%{"query" => params}` — the code, the state — when the
  browser arrives there. **Never listen on a local port for that**: the
  person may be on another machine. `fields:` is `[%{id: "code", label:
  "验证码"}]` for values to type; `timeout:` in ms (10 minutes by default).
  Outside an agent (tests) this returns `{:error, :no_agent}`.
  """
  @spec ask(t | map, keyword) :: {:ok, map} | {:error, :cancelled | :timeout | :no_agent}
  def ask(%{thread_id: thread_id, item_id: item_id}, opts) when is_binary(thread_id) do
    request = %{
      title: Keyword.get(opts, :title, "需要你操作"),
      text: Keyword.get(opts, :text, ""),
      url: Keyword.get(opts, :url),
      fields: Keyword.get(opts, :fields, []),
      callback?: Keyword.get(opts, :callback, false),
      timeout: Keyword.get(opts, :timeout, 600_000),
      item_id: item_id
    }

    Longx.Agent.ask(thread_id, request)
  end

  def ask(_context, _opts), do: {:error, :no_agent}

  @doc "Sends output to the UI as it happens; a no-op without an emitter."
  @spec emit(t | map, String.t()) :: :ok
  def emit(%{emit: emit}, text) when is_function(emit, 1) and is_binary(text), do: emit.(text)
  def emit(_context, _text), do: :ok

  @doc "Resolves a path a tool got against the working directory."
  @spec path(t | map, String.t()) :: String.t()
  def path(%{cwd: cwd}, path) when is_binary(cwd), do: Path.expand(path, cwd)
  def path(_context, path), do: Path.expand(path)
end
