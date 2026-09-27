// The realm's floor — what the protocol needs before any prelude: how a cell
// runs and reports, console, the wrapped host calls. Longx's prelude
// (priv/agent/browser/prelude.js) builds the browser primitives on top.
(function () {
  const describe = (e) => {
    if (e && typeof e === "object") {
      const stack = typeof e.stack === "string" ? e.stack : "";
      const head = e.name ? `${e.name}: ${e.message}` : String(e);
      return stack && stack.indexOf(head) === 0 ? stack : head + (stack ? "\n" + stack : "");
    }
    return String(e);
  };
  const serialize = (v) => {
    if (v === undefined) return null;
    try {
      const json = JSON.stringify(v);
      return json === undefined ? JSON.stringify(String(v)) : json;
    } catch (_e) {
      return JSON.stringify(String(v));
    }
  };
  // a cell: the code as the body of an async function, its settlement reported once
  globalThis.__longx_run = (fn) =>
    Promise.resolve()
      .then(fn)
      .then(
        (v) => __longx_done(serialize(v), null),
        (e) => __longx_done(null, describe(e)),
      );
  // host promises reject with a plain string: make it an Error the cell can catch
  const rawCdp = globalThis.__longx_cdp;
  globalThis.__longx_cdp = (target, method, params) =>
    rawCdp(target, method, params === undefined ? {} : params).catch((e) => {
      throw e instanceof Error ? e : new Error(String(e));
    });
  const format = (v) => {
    if (typeof v === "string") return v;
    if (v instanceof Error) return describe(v);
    if (v === undefined) return "undefined";
    try {
      return JSON.stringify(v);
    } catch (_e) {
      return String(v);
    }
  };
  const log = (...args) => __longx_log(args.map(format).join(" "));
  globalThis.console = { log, info: log, warn: log, error: log, debug: log, dir: log, table: log };
})();
