defmodule Longx.Agent.Tools.Patch do
  @moduledoc """
  codex's `apply_patch` format — the one edit format the models tuned for
  codex already speak — parsed and applied in Elixir:

      *** Begin Patch
      *** Add File: path            (+ lines)
      *** Delete File: path
      *** Update File: path         (*** Move to: new path)
      @@ context line               (optional; locates the change)
       unchanged / -removed / +added lines
      *** End of File               (the chunk must end the file)
      *** End Patch

  `parse/1` gives hunks; `apply/2` applies them under a directory, all
  reads and matching first, then the writes — an update whose context is
  not found leaves every file untouched and names the line. Matching is
  exact, then ignoring trailing whitespace, then surrounding whitespace
  (what codex's `apply-patch` crate does); the file's own text is kept
  for the context lines. `unified_diff/3` is the UI's diff of one change.
  """

  @type chunk :: %{
          context: String.t() | nil,
          lines: [{:ctx | :del | :add, String.t()}],
          old: [String.t()],
          new: [String.t()],
          eof?: boolean
        }
  @type hunk ::
          {:add, String.t(), String.t()}
          | {:delete, String.t()}
          | {:update, String.t(), String.t() | nil, [chunk]}

  @begin "*** Begin Patch"
  @end_ "*** End Patch"
  @add "*** Add File: "
  @delete "*** Delete File: "
  @update "*** Update File: "
  @move "*** Move to: "
  @eof "*** End of File"

  ## Parsing

  @spec parse(String.t()) :: {:ok, [hunk]} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    lines = text |> String.split(~r/\r?\n/) |> Enum.map(&String.trim_trailing(&1, "\r"))

    with {:ok, body} <- unwrap(lines) do
      # line numbers as codex counts them: `*** Begin Patch` is line 1
      hunks(body, 2, [])
    end
  end

  # the patch between its two markers (surrounding whitespace on markers tolerated)
  defp unwrap(lines) do
    trimmed = Enum.map(lines, &String.trim/1)

    with {:ok, first} <- index(trimmed, @begin, "missing '#{@begin}'"),
         {:ok, last} <- index(trimmed, @end_, "missing '#{@end_}'") do
      if last > first,
        do: {:ok, Enum.slice(lines, (first + 1)..(last - 1)//1)},
        else: {:error, "'#{@end_}' before '#{@begin}'"}
    end
  end

  defp index(lines, marker, error) do
    case Enum.find_index(lines, &(&1 == marker)) do
      nil -> {:error, error}
      i -> {:ok, i}
    end
  end

  defp hunks([], _n, acc), do: {:ok, Enum.reverse(acc)}

  defp hunks([line | rest], n, acc) do
    cond do
      String.starts_with?(String.trim_leading(line), @add) ->
        {content, rest} = Enum.split_while(rest, &String.starts_with?(&1, "+"))
        path = after_marker(line, @add)
        text = content |> Enum.map_join("", &(String.slice(&1, 1..-1//1) <> "\n"))
        n = n + 1 + length(content)

        # an empty line with the file's '+' lines going on after it is inside the new
        # file: codex refuses it there (an empty line between two hunks is let pass)
        if inside_new_file?(rest),
          do: not_a_header("", n),
          else: hunks(rest, n, [{:add, path, text} | acc])

      String.starts_with?(String.trim_leading(line), @delete) ->
        hunks(rest, n + 1, [{:delete, after_marker(line, @delete)} | acc])

      String.starts_with?(String.trim_leading(line), @update) ->
        path = after_marker(line, @update)

        {move, rest} =
          case rest do
            [next | more] ->
              if String.starts_with?(String.trim_leading(next), @move),
                do: {after_marker(next, @move), more},
                else: {nil, rest}

            [] ->
              {nil, []}
          end

        {body, rest} = Enum.split_while(rest, &(not marker?(&1)))
        n = n + 1 + if(move, do: 1, else: 0) + length(body)

        with {:ok, chunks} <- chunks(body) do
          hunks(rest, n, [{:update, path, move, chunks} | acc])
        end

      String.trim(line) == "" ->
        hunks(rest, n + 1, acc)

      true ->
        not_a_header(String.trim(line), n)
    end
  end

  # empty lines, then the new file's '+' lines again
  defp inside_new_file?([first | _] = rest) do
    blank? = &(String.trim(&1) == "")
    blank?.(first) and match?(["+" <> _ | _], Enum.drop_while(rest, blank?))
  end

  defp inside_new_file?([]), do: false

  # codex's words (apply-patch/src/streaming_parser.rs, InvalidHunkError's display)
  defp not_a_header(trimmed, n),
    do:
      {:error,
       "invalid hunk at line #{n}, '#{trimmed}' is not a valid hunk header. Valid hunk headers: '*** Add File: {path}', '*** Delete File: {path}', '*** Update File: {path}'"}

  defp marker?(line) do
    t = String.trim_leading(line)

    String.starts_with?(t, @add) or String.starts_with?(t, @delete) or
      String.starts_with?(t, @update)
  end

  defp after_marker(line, marker) do
    line |> String.trim_leading() |> String.replace_prefix(marker, "") |> String.trim()
  end

  # an update's body: chunks introduced by `@@` (with or without a context
  # line); the first chunk may have no `@@` at all
  defp chunks(body) do
    body
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      cond do
        line == "@@" or String.starts_with?(line, "@@ ") ->
          context = line |> String.replace_prefix("@@", "") |> String.trim()
          {:cont, {:ok, [new_chunk(if(context == "", do: nil, else: context)) | acc]}}

        String.trim(line) == @eof ->
          {:cont, {:ok, mark_eof(acc)}}

        true ->
          case tagged(line) do
            {:ok, tagged} -> {:cont, {:ok, push(acc, tagged)}}
            :error -> {:halt, {:error, "unexpected line in update hunk: #{inspect(line)}"}}
          end
      end
    end)
    |> case do
      {:ok, acc} ->
        {:ok,
         acc |> Enum.reverse() |> Enum.map(&finish_chunk/1) |> Enum.reject(&(&1.lines == []))}

      error ->
        error
    end
  end

  defp new_chunk(context), do: %{context: context, lines: [], eof?: false}

  defp tagged(" " <> text), do: {:ok, {:ctx, text}}
  defp tagged("-" <> text), do: {:ok, {:del, text}}
  defp tagged("+" <> text), do: {:ok, {:add, text}}
  # a blank context line arrives with its space trimmed by some models
  defp tagged(""), do: {:ok, {:ctx, ""}}
  defp tagged(_), do: :error

  defp push([], tagged), do: [%{new_chunk(nil) | lines: [tagged]}]
  defp push([chunk | rest], tagged), do: [%{chunk | lines: [tagged | chunk.lines]} | rest]

  defp mark_eof([]), do: [%{new_chunk(nil) | eof?: true}]
  defp mark_eof([chunk | rest]), do: [%{chunk | eof?: true} | rest]

  defp finish_chunk(%{lines: lines} = chunk) do
    lines = Enum.reverse(lines)

    Map.merge(chunk, %{
      lines: lines,
      old: for({tag, text} <- lines, tag in [:ctx, :del], do: text),
      new: for({tag, text} <- lines, tag in [:ctx, :add], do: text)
    })
  end

  ## Applying

  @doc """
  Applies the hunks under `cwd`. Everything is read and matched first;
  the writes happen only when every hunk resolved. Returns the changes
  for the UI: `path`, `kind` (add / update / delete), `moved_from`, `diff`.
  """
  @spec apply([hunk], Path.t()) :: {:ok, [map]} | {:error, String.t()}
  def apply(hunks, cwd) do
    with :ok <- once_each(hunks, cwd),
         {:ok, plans} <- plan_all(hunks, cwd, []) do
      {:ok, Enum.map(plans, &execute/1)}
    end
  end

  # one operation per file, as codex verifies before it applies anything
  # (apply-patch/src/invocation.rs): every hunk was planned against the file as it
  # was, so a second section of one file wrote over the first's change, reported done
  defp once_each(hunks, cwd) do
    hunks
    |> Enum.map(&Path.expand(elem(&1, 1), cwd))
    |> Enum.reduce_while(%{}, fn path, seen ->
      if Map.has_key?(seen, path),
        do: {:halt, {:error, "multiple operations target #{path}"}},
        else: {:cont, Map.put(seen, path, true)}
    end)
    |> case do
      {:error, _} = error -> error
      _seen -> :ok
    end
  end

  defp plan_all([], _cwd, acc), do: {:ok, Enum.reverse(acc)}

  defp plan_all([hunk | rest], cwd, acc) do
    with {:ok, plan} <- plan(hunk, cwd), do: plan_all(rest, cwd, [plan | acc])
  end

  defp plan({:add, path, content}, cwd) do
    full = Path.expand(path, cwd)
    before = if File.regular?(full), do: File.read!(full), else: nil
    {:ok, %{kind: "add", path: full, from: nil, before: before, after: content}}
  end

  defp plan({:delete, path}, cwd) do
    full = Path.expand(path, cwd)

    case File.read(full) do
      {:ok, before} -> {:ok, %{kind: "delete", path: full, from: nil, before: before, after: nil}}
      {:error, reason} -> {:error, "cannot delete #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp plan({:update, path, move, chunks}, cwd) do
    full = Path.expand(path, cwd)

    with {:ok, before} <- read(full, path),
         {:ok, updated} <- rewrite(before, chunks, path) do
      target = if move, do: Path.expand(move, cwd), else: full

      {:ok,
       %{
         kind: "update",
         path: target,
         from: if(move, do: full, else: nil),
         before: before,
         after: updated
       }}
    end
  end

  defp read(full, path) do
    case File.read(full) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, "cannot update #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp execute(%{kind: "delete", path: path} = plan) do
    File.rm!(path)
    change(plan)
  end

  defp execute(%{path: path, after: content, from: from} = plan) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    if from && from != path, do: File.rm!(from)
    change(plan)
  end

  defp change(%{kind: kind, path: path, from: from, before: before, after: after_text}) do
    %{
      "path" => path,
      "kind" => kind,
      "diff" => unified_diff(Path.basename(path), before, after_text)
    }
    |> then(&if(from, do: Map.put(&1, "moved_from", from), else: &1))
  end

  # the chunks applied in order, each searched from where the previous ended
  defp rewrite(text, chunks, path) do
    {lines, newline?} = split_lines(text)

    chunks
    |> Enum.reduce_while({:ok, lines, 0}, fn chunk, {:ok, lines, cursor} ->
      case apply_chunk(lines, cursor, chunk) do
        {:ok, lines, cursor} -> {:cont, {:ok, lines, cursor}}
        {:error, why} -> {:halt, {:error, "cannot update #{path}: #{why}"}}
      end
    end)
    |> case do
      {:ok, lines, _} -> {:ok, join_lines(lines, newline?)}
      error -> error
    end
  end

  defp split_lines(""), do: {[], false}

  defp split_lines(text) do
    newline? = String.ends_with?(text, "\n")
    lines = String.split(text, "\n")
    {if(newline?, do: Enum.drop(lines, -1), else: lines), newline?}
  end

  defp join_lines(lines, newline?),
    do: Enum.join(lines, "\n") <> if(newline? or lines != [], do: "\n", else: "")

  defp apply_chunk(lines, cursor, %{
         context: context,
         old: old,
         new: new,
         lines: tagged,
         eof?: eof?
       }) do
    with {:ok, cursor} <- locate_context(lines, cursor, context),
         {:ok, at} <- locate(lines, cursor, old, eof?) do
      # the file's own text stays on the context lines (a fuzzy match kept trailing spaces)
      original = Enum.slice(lines, at, length(old))

      replacement =
        tagged
        |> Enum.reduce({[], original}, fn
          {:ctx, _text}, {out, [orig | rest]} -> {[orig | out], rest}
          {:del, _text}, {out, [_ | rest]} -> {out, rest}
          {:add, text}, {out, rest} -> {[text | out], rest}
        end)
        |> elem(0)
        |> Enum.reverse()

      _ = new

      {:ok, Enum.slice(lines, 0, at) ++ replacement ++ Enum.drop(lines, at + length(old)),
       at + length(replacement)}
    end
  end

  defp locate_context(_lines, cursor, nil), do: {:ok, cursor}

  defp locate_context(lines, cursor, context) do
    case find(lines, cursor, [context], false) do
      {:ok, at} -> {:ok, at + 1}
      :error -> {:error, "context line not found: #{inspect(context)}"}
    end
  end

  defp locate(_lines, cursor, [], _eof?), do: {:ok, cursor}

  defp locate(lines, cursor, old, eof?) do
    case find(lines, cursor, old, eof?) do
      {:ok, at} -> {:ok, at}
      :error -> {:error, explain_miss(lines, cursor, old)}
    end
  end

  # The block (context and deleted lines) is matched as a whole, line by
  # line. An error naming only its first line sent an agent chasing
  # encodings when that line was in the file and the block broke two lines
  # later (a blank line left out of the context). So: where the block
  # starts matching, where it stops, both sides quoted.
  defp explain_miss(lines, cursor, [first | _] = old) do
    normalise = &String.trim/1

    starts =
      for {line, i} <- Enum.with_index(lines),
          i >= cursor,
          normalise.(line) == normalise.(first),
          do: i

    case starts do
      [] ->
        nearest = nearest_line(lines, cursor, first)

        "lines to replace not found: the block's first line #{inspect(first)} is nowhere in the file" <>
          if(nearest,
            do:
              " (after line #{cursor + 1}); nearest is line #{nearest.n} #{inspect(nearest.text)}",
            else: ""
          ) <>
          " — every context and deleted line must reproduce the file line by line, blank lines included"

      _ ->
        # the start that matches the longest prefix of the block
        {at, matched} =
          Enum.max_by(starts, fn at ->
            old
            |> Enum.with_index()
            |> Enum.take_while(fn {want, k} ->
              (line = Enum.at(lines, at + k)) != nil and normalise.(line) == normalise.(want)
            end)
            |> length()
          end)
          |> then(fn at ->
            n =
              old
              |> Enum.with_index()
              |> Enum.take_while(fn {want, k} ->
                (line = Enum.at(lines, at + k)) != nil and normalise.(line) == normalise.(want)
              end)
              |> length()

            {at, n}
          end)

        want = Enum.at(old, matched)
        have = Enum.at(lines, at + matched)

        detail =
          cond do
            have == nil ->
              "the file ends there"

            String.trim(have) == "" ->
              "file has #{inspect(have)} (a blank line the patch left out)"

            String.trim(want) == "" ->
              "file has #{inspect(have)} where the patch has a blank line"

            true ->
              "file has #{inspect(have)}"
          end

        "lines to replace not found: the block matches from line #{at + 1} #{inspect(first)} for #{matched} line(s), then at line #{at + matched + 1} expected #{inspect(want)} but #{detail} — every context and deleted line must reproduce the file line by line, blank lines included"
    end
  end

  # the file line most like the wanted one (a shared prefix), for the hint
  defp nearest_line(lines, cursor, want) do
    w = String.trim(want)

    lines
    |> Enum.with_index()
    |> Enum.drop(cursor)
    |> Enum.map(fn {line, i} -> {common_prefix_length(String.trim(line), w), i, line} end)
    |> Enum.filter(fn {score, _, _} -> score >= 3 end)
    |> Enum.max_by(fn {score, _, _} -> score end, fn -> nil end)
    |> case do
      nil -> nil
      {_, i, line} -> %{n: i + 1, text: line}
    end
  end

  defp common_prefix_length(a, b) do
    a
    |> String.graphemes()
    |> Enum.zip(String.graphemes(b))
    |> Enum.take_while(fn {x, y} -> x == y end)
    |> length()
  end

  # exact, then ignoring trailing whitespace, then surrounding whitespace
  defp find(lines, cursor, needle, eof?) do
    Enum.find_value([& &1, &String.trim_trailing/1, &String.trim/1], :error, fn norm ->
      case find_with(Enum.map(lines, norm), cursor, Enum.map(needle, norm), eof?) do
        nil -> nil
        at -> {:ok, at}
      end
    end)
  end

  defp find_with(lines, cursor, needle, eof?) do
    n = length(needle)
    last = length(lines) - n

    if eof? do
      if last >= cursor and Enum.slice(lines, last, n) == needle, do: last, else: nil
    else
      Enum.find(cursor..max(last, cursor - 1)//1, fn i -> Enum.slice(lines, i, n) == needle end)
    end
  end

  ## Diff

  @doc "A unified diff of one file (nil = absent) with 3 lines of context, for the UI."
  @spec unified_diff(String.t(), String.t() | nil, String.t() | nil) :: String.t()
  def unified_diff(name, before, after_text) do
    {a, _} = split_lines(before || "")
    {b, _} = split_lines(after_text || "")

    header =
      "--- #{if before, do: "a/#{name}", else: "/dev/null"}\n+++ #{if after_text, do: "b/#{name}", else: "/dev/null"}\n"

    case hunk(a, b) do
      nil -> header
      body -> header <> body
    end
  end

  @context 3

  # one hunk from the first to the last change, with context around it
  defp hunk(a, b) do
    prefix = common_prefix(a, b)
    suffix = common_suffix(Enum.drop(a, prefix), Enum.drop(b, prefix))
    mid_a = Enum.slice(a, prefix, length(a) - prefix - suffix)
    mid_b = Enum.slice(b, prefix, length(b) - prefix - suffix)

    if mid_a == [] and mid_b == [] do
      nil
    else
      ctx_before = Enum.slice(a, max(prefix - @context, 0), min(@context, prefix))
      ctx_after = Enum.slice(a, prefix + length(mid_a), min(@context, suffix))
      body = diff_lines(mid_a, mid_b)
      base = max(prefix - @context, 0)
      a_count = length(ctx_before) + length(mid_a) + length(ctx_after)
      b_count = length(ctx_before) + length(mid_b) + length(ctx_after)
      # an empty side names the line before it (unified diff convention)
      a_start = if a_count == 0, do: base, else: base + 1
      b_start = if b_count == 0, do: base, else: base + 1

      "@@ -#{range(a_start, a_count)} +#{range(b_start, b_count)} @@\n" <>
        Enum.map_join(ctx_before, "", &(" " <> &1 <> "\n")) <>
        body <>
        Enum.map_join(ctx_after, "", &(" " <> &1 <> "\n"))
    end
  end

  defp range(start, 1), do: "#{start}"
  defp range(start, count), do: "#{start},#{count}"

  defp common_prefix(a, b),
    do: a |> Enum.zip(b) |> Enum.take_while(fn {x, y} -> x == y end) |> length()

  defp common_suffix(a, b), do: common_prefix(Enum.reverse(a), Enum.reverse(b))

  # LCS over the changed middle (small in practice): removed lines first, then added
  defp diff_lines(a, b) do
    lcs = lcs(a, b)
    walk(a, b, lcs, [])
  end

  defp walk([], [], _lcs, out), do: out |> Enum.reverse() |> Enum.join("")

  defp walk(a, [], _lcs, out),
    do: walk([], [], [], Enum.reverse(Enum.map(a, &("-" <> &1 <> "\n"))) ++ out)

  defp walk([], b, _lcs, out),
    do: walk([], [], [], Enum.reverse(Enum.map(b, &("+" <> &1 <> "\n"))) ++ out)

  defp walk([x | ra] = a, [y | rb] = b, [c | rc] = lcs, out) do
    cond do
      x == c and y == c -> walk(ra, rb, rc, [" " <> x <> "\n" | out])
      x != c -> walk(ra, b, lcs, ["-" <> x <> "\n" | out])
      true -> walk(a, rb, lcs, ["+" <> y <> "\n" | out])
    end
  end

  defp walk(a, b, [], out) do
    removed = Enum.map(a, &("-" <> &1 <> "\n"))
    added = Enum.map(b, &("+" <> &1 <> "\n"))
    walk([], [], [], Enum.reverse(removed ++ added) ++ out)
  end

  # classic DP longest common subsequence, as a list
  defp lcs(a, b) do
    a = List.to_tuple(a)
    b = List.to_tuple(b)
    n = tuple_size(a)
    m = tuple_size(b)

    table =
      for i <- n..0//-1, j <- m..0//-1, reduce: %{} do
        acc ->
          value =
            cond do
              i == n or j == m -> 0
              elem(a, i) == elem(b, j) -> 1 + Map.fetch!(acc, {i + 1, j + 1})
              true -> max(Map.fetch!(acc, {i + 1, j}), Map.fetch!(acc, {i, j + 1}))
            end

          Map.put(acc, {i, j}, value)
      end

    read_lcs(a, b, table, 0, 0, [])
  end

  defp read_lcs(a, b, table, i, j, acc) do
    cond do
      i == tuple_size(a) or j == tuple_size(b) ->
        Enum.reverse(acc)

      elem(a, i) == elem(b, j) ->
        read_lcs(a, b, table, i + 1, j + 1, [elem(a, i) | acc])

      Map.fetch!(table, {i + 1, j}) >= Map.fetch!(table, {i, j + 1}) ->
        read_lcs(a, b, table, i + 1, j, acc)

      true ->
        read_lcs(a, b, table, i, j + 1, acc)
    end
  end
end
