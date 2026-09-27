defmodule Longx.Chrome.RuntimeTest do
  # the real `shim js` under Longx.Chrome.Runtime, a test function playing the
  # CDP side (the browser session's proxy)
  use ExUnit.Case, async: true

  alias Longx.Chrome.Runtime

  defp start!(opts \\ []) do
    test = self()

    cdp =
      Keyword.get(opts, :cdp, fn %{target: target, method: method, params: params} ->
        send(test, {:cdp, target, method, params})
        {:ok, %{"echo" => method}}
      end)

    start_supervised!(
      {Runtime, prelude: Keyword.get(opts, :prelude, ""), cdp: cdp, name: nil},
      restart: :temporary
    )
  end

  test "a cell's value, console output and images come back" do
    rt = start!()
    assert {:ok, result} = Runtime.execute(rt, "console.log('hi', 1); return {a: [1, 2]}", 5_000)
    assert result.value == %{"a" => [1, 2]}
    assert result.output == "hi 1\n"
    assert result.error == nil
    refute result.interrupted

    assert {:ok, %{images: [%{mime: "image/png", data: "AAAA"}]}} =
             Runtime.execute(rt, "__longx_image('image/png', 'AAAA')", 5_000)
  end

  test "console output streams to the emitter as it happens" do
    rt = start!()
    test = self()

    assert {:ok, %{output: "one\ntwo\n"}} =
             Runtime.execute(rt, "console.log('one'); console.log('two')", 5_000,
               emit: fn text -> send(test, {:emitted, text}) end
             )

    assert_received {:emitted, "one\n"}
    assert_received {:emitted, "two\n"}
  end

  test "state persists between cells, errors are reported" do
    rt = start!()
    assert {:ok, _} = Runtime.execute(rt, "const n = 20; function d(x) { return x * 2 }", 5_000)
    assert {:ok, %{value: 40}} = Runtime.execute(rt, "return d(n)", 5_000)

    assert {:ok, %{error: "Error: boom" <> _, value: nil}} =
             Runtime.execute(rt, "throw new Error('boom')", 5_000)
  end

  test "host calls go through the cdp function, an error is catchable in the cell" do
    rt =
      start!(
        cdp: fn
          %{target: "tab:7", method: "Page.navigate", params: %{"url" => url}} ->
            {:ok, %{"frameId" => "F", "url" => url}}

          %{method: "Boom"} ->
            {:error, "no such target"}
        end
      )

    assert {:ok, %{value: "F https://x.test/"}} =
             Runtime.execute(
               rt,
               "const r = await __longx_cdp('tab:7', 'Page.navigate', {url: 'https://x.test/'}); return r.frameId + ' ' + r.url",
               5_000
             )

    assert {:ok, %{value: "caught: no such target"}} =
             Runtime.execute(
               rt,
               "try { await __longx_cdp('tab:7', 'Boom', {}) } catch (e) { return 'caught: ' + e.message }",
               5_000
             )
  end

  test "the deadline interrupts a busy cell and the realm starts over" do
    rt = start!(prelude: "globalThis.p = 'prelude'")
    assert {:ok, _} = Runtime.execute(rt, "kept = 1", 5_000)
    assert {:ok, result} = Runtime.execute(rt, "while (true) {}", 200)
    assert result.interrupted
    assert result.reset

    assert {:ok, %{value: ["prelude", "undefined"]}} =
             Runtime.execute(rt, "return [p, typeof kept]", 5_000)
  end

  test "a cell waiting on a slow host call is interrupted at the deadline too" do
    rt =
      start!(
        cdp: fn _call ->
          Process.sleep(2_000)
          {:ok, %{}}
        end
      )

    assert {:ok, %{interrupted: true}} =
             Runtime.execute(rt, "await __longx_cdp('tab:1', 'Slow', {}); return 'late'", 300)

    assert {:ok, %{value: 1}} = Runtime.execute(rt, "return 1", 5_000)
  end

  test "a held cell outlives its deadline until resumed" do
    rt =
      start!(
        cdp: fn %{runtime: runtime} ->
          Runtime.hold(runtime)
          Process.sleep(700)
          Runtime.resume(runtime)
          {:ok, %{"ok" => true}}
        end
      )

    assert {:ok, %{value: true, interrupted: false}} =
             Runtime.execute(
               rt,
               "const r = await __longx_cdp('tab:1', 'Ask', {}); return r.ok",
               300
             )
  end

  test "the prelude is loaded before the first cell" do
    rt = start!(prelude: "globalThis.greet = (n) => 'hi ' + n")
    assert {:ok, %{value: "hi x"}} = Runtime.execute(rt, "return greet('x')", 5_000)
  end

  test "a shim that died comes back for the next cell, saying so" do
    rt = start!()
    assert {:ok, _} = Runtime.execute(rt, "state = 1", 5_000)
    Runtime.kill_for_test(rt)

    assert {:ok, %{value: "undefined", reset: true}} =
             Runtime.execute(rt, "return typeof state", 5_000)
  end
end
