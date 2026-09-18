defmodule Longx.Agent.Watch do
  @moduledoc """
  What a watch file defines: a module `use`ing this one, with a schedule
  in its head and a `run/1`.

      # .longx/local/watches/deploy_health.exs
      defmodule DeployHealth do
        use Longx.Agent.Watch

        every "*/5 * * * *"                 # or once "2026-09-19T08:00:00+08:00", or webhook true
        expires "2026-09-20T00:00:00+08:00" # optional; or max_runs 24
        timeout 30_000                      # optional, the default

        def run(ctx) do
          {code, out} = shell(ctx, "curl -fsS -m 5 http://localhost:8080/health")
          status = if code == 0, do: :ok, else: :fail

          if status != ctx.state[:status],
            do: send(ctx, "main", "health went from \#{ctx.state[:status]} to \#{status}:\\n\#{out}")

          {:ok, %{status: status}}
        end
      end

  A watch is a plain script: Oban is its clock (`Longx.Watches`), the
  sessions' mailboxes its outlet. It decides by itself what to check and
  whom to tell — a loop is `send(ctx, "main", "go on")`, a monitor sends
  when something changed, a duty of its own sends to `:self`, the session
  named after the watch. The runtime keeps no policy: `ctx.state` is
  whatever the last run returned, the head says when to run, and that is
  all.

  The head is data (`definition/1`): `every` a five-field cron read in the
  machine's local time, `once` an ISO 8601 instant (with an offset, else
  local), `webhook true` for `POST /hooks/<token>`; `expires`, `max_runs`,
  `timeout` (ms, 30 s), `budget` (sends per hour, 6). `run/1` answers
  `{:ok, state}` — a map kept for the next run — or `{:error, why}`; a
  raise is an error too. The helpers (`shell/3`, `http/3`,
  `credential_request/4`, `knowledge_read/2`, `send/4`, `log/2`) are
  imported; `send/4` delivers through `ctx.deliver` — a function, or `:dry`
  for a run that only records (`watch_run`).
  """

  @type definition :: %{
          kind: :cron | :once | :webhook,
          cron: String.t() | nil,
          at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          max_runs: pos_integer | nil,
          timeout: pos_integer,
          budget: pos_integer
        }

  @callback run(ctx :: map) :: {:ok, map} | {:error, term}

  @default_timeout 30_000
  @default_budget 6

  defmacro __using__(_opts) do
    quote do
      @behaviour Longx.Agent.Watch
      import Longx.Agent.Watch,
        only: [every: 1, once: 1, webhook: 1, expires: 1, max_runs: 1, timeout: 1, budget: 1]

      import Longx.Agent.Watch.Helpers
      import Kernel, except: [send: 2]

      Module.register_attribute(__MODULE__, :longx_watch, accumulate: true)
      @before_compile Longx.Agent.Watch
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc false
      def __watch__, do: Enum.reverse(@longx_watch)
    end
  end

  @doc "A five-field crontab, in the machine's local time."
  defmacro every(cron), do: quote(do: @longx_watch({:every, unquote(cron)}))

  @doc "One instant, ISO 8601; without an offset it is local time."
  defmacro once(at), do: quote(do: @longx_watch({:once, unquote(at)}))

  @doc "Run when `POST /hooks/<token>` arrives (the body is `ctx.payload`)."
  defmacro webhook(flag), do: quote(do: @longx_watch({:webhook, unquote(flag)}))

  @doc "After this instant the watch is over (the file stays, the row says expired)."
  defmacro expires(at), do: quote(do: @longx_watch({:expires, unquote(at)}))

  @doc "After this many runs the watch is over."
  defmacro max_runs(n), do: quote(do: @longx_watch({:max_runs, unquote(n)}))

  @doc "How long a run may take, in milliseconds (default 30 s)."
  defmacro timeout(ms), do: quote(do: @longx_watch({:timeout, unquote(ms)}))

  @doc "How many messages a watch may send per hour (default 6)."
  defmacro budget(n), do: quote(do: @longx_watch({:budget, unquote(n)}))

  @doc "Whether the module is a watch (it `use`d this module)."
  @spec watch?(module) :: boolean
  def watch?(module) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :__watch__, 0)

  @doc "The definition read off the module's head, or why it is not a valid watch."
  @spec definition(module) :: {:ok, definition} | {:error, String.t()}
  def definition(module) do
    if watch?(module) do
      head = module.__watch__()

      with :ok <- runnable(module),
           {:ok, kind, cron, at} <- schedule(head),
           {:ok, expires_at} <- instant(Keyword.get(head, :expires), "expires"),
           {:ok, max_runs} <- positive(Keyword.get(head, :max_runs), "max_runs"),
           {:ok, timeout} <- positive(Keyword.get(head, :timeout, @default_timeout), "timeout"),
           {:ok, budget} <- positive(Keyword.get(head, :budget, @default_budget), "budget") do
        {:ok,
         %{
           kind: kind,
           cron: cron,
           at: at,
           expires_at: expires_at,
           max_runs: max_runs,
           timeout: timeout,
           budget: budget
         }}
      end
    else
      {:error, "#{inspect(module)} is not a watch (it does not `use Longx.Agent.Watch`)"}
    end
  end

  @spec definition!(module) :: definition
  def definition!(module) do
    case definition(module) do
      {:ok, d} -> d
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp runnable(module) do
    if function_exported?(module, :run, 1),
      do: :ok,
      else: {:error, "#{inspect(module)} defines no run/1"}
  end

  defp schedule(head) do
    every = Keyword.get(head, :every)
    once = Keyword.get(head, :once)
    hook = Keyword.get(head, :webhook, false) == true

    case {every, once, hook} do
      {cron, nil, false} when is_binary(cron) ->
        case Oban.Cron.Expression.parse(cron) do
          {:ok, _} -> {:ok, :cron, cron, nil}
          {:error, e} -> {:error, "every: not a cron expression (#{Exception.message(e)})"}
        end

      {nil, at, false} when is_binary(at) ->
        with {:ok, at} <- instant(at, "once"), do: {:ok, :once, nil, at}

      {nil, nil, true} ->
        {:ok, :webhook, nil, nil}

      {nil, nil, false} ->
        {:error, "a watch needs a schedule: every \"<cron>\", once \"<instant>\" or webhook true"}

      _ ->
        {:error, "a watch has one schedule: every, once or webhook, not several"}
    end
  end

  defp instant(nil, _field), do: {:ok, nil}

  defp instant(text, field) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} ->
        {:ok, at}

      {:error, :missing_offset} ->
        case NaiveDateTime.from_iso8601(text) do
          {:ok, naive} -> {:ok, local_to_utc(naive)}
          {:error, _} -> {:error, "#{field}: not an ISO 8601 instant: #{text}"}
        end

      {:error, _} ->
        {:error, "#{field}: not an ISO 8601 instant: #{text}"}
    end
  end

  defp instant(other, field), do: {:error, "#{field}: expected a string, got #{inspect(other)}"}

  defp positive(nil, _field), do: {:ok, nil}
  defp positive(n, _field) when is_integer(n) and n > 0, do: {:ok, n}

  defp positive(other, field),
    do: {:error, "#{field}: expected a positive integer, got #{inspect(other)}"}

  @doc """
  When the watch is due next after `now` (UTC): the cron's next minute in
  the machine's local time, the `once` instant (nil once it passed), nil
  for a webhook.
  """
  @spec next_due_at(definition, DateTime.t()) :: DateTime.t() | nil
  def next_due_at(%{kind: :webhook}, _now), do: nil

  def next_due_at(%{kind: :once, at: at}, now) do
    if DateTime.compare(at, now) == :gt, do: at, else: nil
  end

  def next_due_at(%{kind: :cron, cron: cron}, now) do
    # the cron reads local clock time: the offset the machine has right now
    # is applied both ways (a DST change between now and then is off by it)
    offset = local_offset_seconds()
    local = now |> DateTime.add(offset, :second) |> DateTime.truncate(:second)

    case cron |> Oban.Cron.Expression.parse!() |> Oban.Cron.Expression.next_at(local) do
      %DateTime{} = next -> DateTime.add(next, -offset, :second)
      _ -> nil
    end
  end

  defp local_offset_seconds do
    local = NaiveDateTime.local_now()
    utc = NaiveDateTime.utc_now()
    # whole minutes: the two clocks are read a few microseconds apart
    div(NaiveDateTime.diff(local, utc, :second) + 30, 60) * 60
  end

  defp local_to_utc(%NaiveDateTime{} = naive) do
    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.add(-local_offset_seconds(), :second)
  end

  @doc """
  Runs the watch in the calling process: `module.run/1` on a ctx made of
  `attrs` (`name`, `project_root`, `state`, `payload`, `deliver`) plus the
  collector the helpers write to. Answers the result (`{:ok, state}` or
  `{:error, message}` — a raise, a bad return), what was sent (`to`,
  `text`, `opts`) and what was logged. Timeouts are the caller's (a task).
  """
  @spec run(module, map) :: %{
          result: {:ok, map} | {:error, String.t()},
          sends: [map],
          log: [String.t()]
        }
  def run(module, attrs) when is_atom(module) and is_map(attrs) do
    {:ok, collector} = Elixir.Agent.start_link(fn -> %{sends: [], log: []} end)

    ctx =
      Map.merge(
        %{name: nil, project_root: File.cwd!(), state: %{}, payload: nil, deliver: :dry},
        attrs
      )
      |> Map.put(:collector, collector)
      |> Map.put(:run_at, DateTime.utc_now())

    result =
      try do
        case module.run(ctx) do
          {:ok, state} when is_map(state) ->
            {:ok, state}

          {:ok, other} ->
            {:error, "run/1 answered {:ok, #{inspect(other)}}; the state must be a map"}

          {:error, why} ->
            {:error, describe(why)}

          other ->
            {:error, "run/1 answered #{inspect(other)}; expected {:ok, state} or {:error, why}"}
        end
      rescue
        e -> {:error, Exception.format(:error, e, __STACKTRACE__) |> String.slice(0, 2_000)}
      catch
        kind, value ->
          {:error, Exception.format(kind, value, __STACKTRACE__) |> String.slice(0, 2_000)}
      end

    %{sends: sends, log: log} = Elixir.Agent.get(collector, & &1)
    Elixir.Agent.stop(collector)
    %{result: result, sends: Enum.reverse(sends), log: Enum.reverse(log)}
  end

  defp describe(why) when is_binary(why), do: why
  defp describe(why), do: inspect(why)

  defmodule Helpers do
    @moduledoc """
    What a watch's `run/1` may call (imported by `use Longx.Agent.Watch`).
    Every helper takes the ctx first.
    """

    @doc """
    Runs a shell command in the project root (bash, the person's
    environment, like `exec_command`): `{exit_code, output}` with stdout
    and stderr together; a start failure is `{127, message}`. `timeout:`
    (ms, default 25 s — under the watch's own).
    """
    @spec shell(map, String.t(), keyword) :: {integer, String.t()}
    def shell(ctx, cmd, opts \\ []) when is_binary(cmd) do
      cwd = Keyword.get(opts, :cwd) || ctx.project_root
      timeout = Keyword.get(opts, :timeout, 25_000)

      case Longx.Shim.run(["bash", "-lc", cmd], cd: cwd, timeout: timeout) do
        {:ok, %{status: status, stdout: out, stderr: err}} ->
          {status, Longx.Agent.Text.utf8(out <> err)}

        {:error, :timeout} ->
          {124, "the command did not finish within #{timeout} ms"}

        {:error, reason} ->
          {127, "could not run: #{inspect(reason)}"}
      end
    end

    @doc "An HTTP request (`Req`): `{:ok, %{status, body}}` or `{:error, reason}`. `method:` (get), `headers:`, `body:`, `timeout:`."
    @spec http(map, String.t(), keyword) :: {:ok, %{status: integer, body: term}} | {:error, term}
    def http(_ctx, url, opts \\ []) when is_binary(url) do
      method = Keyword.get(opts, :method, :get)

      req_opts =
        [
          url: url,
          method: method,
          headers: Keyword.get(opts, :headers, []),
          receive_timeout: Keyword.get(opts, :timeout, 15_000),
          retry: false,
          redirect: false
        ] ++ if(opts[:body], do: [body: opts[:body]], else: [])

      case Req.request(req_opts) do
        {:ok, %Req.Response{status: status, body: body}} -> {:ok, %{status: status, body: body}}
        {:error, reason} -> {:error, reason}
      end
    end

    @doc "A request with a stored credential (`Longx.Credentials.request/4`): the secret never enters the watch."
    @spec credential_request(map, String.t(), String.t(), keyword) :: {:ok, map} | {:error, term}
    def credential_request(_ctx, credential, url, opts \\ []) do
      Longx.Credentials.request(credential, Keyword.get(opts, :method, :get), url, opts)
    end

    @doc "A knowledge doc (`Longx.Agent.Knowledge.read/2`), for the normal state to compare with."
    @spec knowledge_read(map, String.t()) :: {:ok, String.t()} | {:error, String.t()}
    def knowledge_read(ctx, path), do: Longx.Agent.Knowledge.read(ctx.project_root, path)

    @doc """
    A message to a session: `to` is an address (a handle, `~<id suffix>`,
    `<project>:<handle>`) or `:self`, the session named after the watch
    (started when there is none). Delivered when the session is idle
    (`deliver: :idle`; `:now` steers). `:ok`, `{:error, :not_found}`,
    `{:error, :budget}` when the hour's sends are spent.
    """
    @spec send(map, String.t() | :self, String.t(), keyword) :: :ok | {:error, term}
    def send(ctx, to, text, opts \\ []) when is_binary(text) do
      record(ctx, :sends, %{to: to, text: text, opts: opts})

      case ctx.deliver do
        :dry -> :ok
        fun when is_function(fun, 3) -> fun.(to, text, opts)
      end
    end

    @doc "A line the person sees in the watch's last output (2 KB kept)."
    @spec log(map, String.t()) :: :ok
    def log(ctx, text) when is_binary(text), do: record(ctx, :log, text)

    defp record(%{collector: pid}, key, value) when is_pid(pid),
      do: Elixir.Agent.update(pid, &Map.update!(&1, key, fn list -> [value | list] end))

    defp record(_ctx, _key, _value), do: :ok
  end
end
