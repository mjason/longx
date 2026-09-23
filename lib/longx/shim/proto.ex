defmodule Longx.Shim.Proto do
  @moduledoc """
  Wire protocol between `Longx.Shim` and the Go shim in `native/shim`.

  The port is opened with `{:packet, 4}`, so each message here is just
  `<<tag::8, payload::binary>>`; the BEAM adds the length prefix. Tags and
  payload layouts mirror `native/shim/proto.go` — keep both in sync and bump
  `version/0` when the format changes.
  """

  @version "4"

  # host -> shim
  @input 1
  @close_input 2
  @send_output 3
  @send_stderr 4
  @close_output 5
  @close_stderr 6
  @kill 7
  @signal 8
  @env 9
  @send_stats 10

  # shim -> host
  @pid 16
  @output 17
  @output_eof 18
  @stderr 19
  @stderr_eof 20
  @exit_status 21
  @start_error 22
  @send_input 23
  @stats 24

  # 4 byte length prefix + 1 byte tag leaves this much payload in a 64 KiB packet
  @max_chunk 64 * 1024 - 5
  @max_env_entry 0xFFFF

  @type command ::
          :close_input
          | :close_output
          | :close_stderr
          | :send_stats
          | {:input, binary}
          | {:send_output, pos_integer}
          | {:send_stderr, pos_integer}
          | {:kill, non_neg_integer}
          | {:signal, non_neg_integer}
          | {:env, [{String.t(), String.t()}]}

  @type event ::
          {:pid, pos_integer}
          | {:output, binary}
          | {:stderr, binary}
          | :output_eof
          | :stderr_eof
          | {:exit_status, integer}
          | {:start_error, String.t()}
          | :send_input
          | {:stats, stats}
          | {:unknown, byte, binary}

  @typedoc "The child's whole process tree at one instant."
  @type stats :: %{
          processes: non_neg_integer,
          rss_bytes: non_neg_integer,
          cpu_ms: non_neg_integer
        }

  @doc "Protocol version the shim must report from `shim -v`."
  @spec version() :: String.t()
  def version, do: @version

  @doc "Largest `:input` payload / `:send_output` request that fits one packet."
  @spec max_chunk() :: pos_integer
  def max_chunk, do: @max_chunk

  @spec encode(:close_input | :close_output | :close_stderr | :send_stats) :: binary
  def encode(:close_input), do: <<@close_input>>
  def encode(:close_output), do: <<@close_output>>
  def encode(:close_stderr), do: <<@close_stderr>>
  def encode(:send_stats), do: <<@send_stats>>

  @spec encode(atom, term) :: binary
  def encode(:input, data) when is_binary(data) and byte_size(data) <= @max_chunk,
    do: <<@input, data::binary>>

  def encode(:send_output, max) when is_integer(max) and max > 0 and max <= @max_chunk,
    do: <<@send_output, max::unsigned-big-32>>

  def encode(:send_stderr, max) when is_integer(max) and max > 0 and max <= @max_chunk,
    do: <<@send_stderr, max::unsigned-big-32>>

  def encode(:kill, grace_ms) when is_integer(grace_ms) and grace_ms >= 0,
    do: <<@kill, grace_ms::unsigned-big-32>>

  def encode(:signal, signum) when is_integer(signum) and signum >= 0,
    do: <<@signal, signum::unsigned-big-32>>

  def encode(:env, env) when is_list(env) do
    entries =
      Enum.map(env, fn {key, value} ->
        entry = to_string(key) <> "=" <> to_string(value)

        if byte_size(entry) > @max_env_entry do
          raise ArgumentError, "env entry #{inspect(key)} exceeds #{@max_env_entry} bytes"
        end

        <<byte_size(entry)::unsigned-big-16, entry::binary>>
      end)

    IO.iodata_to_binary([@env | entries])
  end

  @spec decode(binary) :: event
  def decode(<<@pid, pid::unsigned-big-32>>), do: {:pid, pid}
  def decode(<<@output, data::binary>>), do: {:output, data}
  def decode(<<@output_eof>>), do: :output_eof
  def decode(<<@stderr, data::binary>>), do: {:stderr, data}
  def decode(<<@stderr_eof>>), do: :stderr_eof
  def decode(<<@exit_status, status::signed-big-32>>), do: {:exit_status, status}
  def decode(<<@start_error, reason::binary>>), do: {:start_error, reason}
  def decode(<<@send_input>>), do: :send_input

  def decode(<<@stats, json::binary>>) do
    case Jason.decode(json) do
      {:ok, %{"processes" => p, "rss_bytes" => rss, "cpu_ms" => cpu}}
      when is_integer(p) and is_integer(rss) and is_integer(cpu) ->
        {:stats, %{processes: p, rss_bytes: rss, cpu_ms: cpu}}

      _ ->
        {:unknown, @stats, json}
    end
  end

  def decode(<<tag, rest::binary>>), do: {:unknown, tag, rest}
end
