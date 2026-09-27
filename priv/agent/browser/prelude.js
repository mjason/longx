// The browser primitives of the `javascript` tool (Longx.Agent.Plugs.Browser),
// loaded into the session's realm (`shim js`) after its bootstrap. Everything
// here ends in `__longx_cdp(target, method, params)`: a `tab:<id>` target is a
// chrome.debugger command on that tab, the `longx` target the session's own
// methods (Longx.Chrome.Session). The shape follows browser-use-pi (MIT).
(function () {
  const cdp = (target, method, params) => __longx_cdp(target, method, params === undefined ? {} : params);
  const longx = (method, params) => cdp("longx", method, params || {});
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const contextGone = /Execution context was destroyed|Cannot find context|Cannot find default execution context|No frame for given id/;

  function controlState(node) {
    const state = {};
    for (const { name, value } of node.properties || []) {
      const observed = value && value.value;
      if (name === "checked" || name === "pressed") {
        if (observed === "mixed") state[name] = "mixed";
        else if (observed === true || observed === "true") state[name] = true;
        else if (observed === false || observed === "false") state[name] = false;
      } else if ((name === "selected" || name === "expanded" || name === "disabled") && typeof observed === "boolean") {
        state[name] = observed;
      }
    }
    return state;
  }

  /** A tab: explicit CDP, page evaluation and observation. No selector/action layer. */
  class Page {
    constructor(id) {
      this.id = id === undefined ? null : id;
    }
    // the current tab is opened on first use, so a cell may start with page.goto(url)
    async _ensure() {
      if (this.id === null) {
        const { tabId } = await longx("longx.tabs.open", {});
        this.id = tabId;
      }
      return "tab:" + this.id;
    }
    async cdp(method, params) {
      const target = await this._ensure();
      return cdp(target, method, params);
    }
    async goto(url) {
      const result = await this.cdp("Page.navigate", { url });
      if (result && result.errorText) throw new Error("Navigation failed: " + result.errorText);
      try {
        await this.waitFor(() => document.readyState !== "loading", undefined, { timeoutMs: 15000 });
      } catch (_e) {}
      return this.info();
    }
    info() {
      return this.evaluate(() => ({ url: location.href, title: document.title }));
    }
    async evaluate(fn, argument) {
      const expression =
        typeof fn === "string" ? fn : `(${fn.toString()})(${argument === undefined ? "undefined" : JSON.stringify(argument)})`;
      const response = await this.cdp("Runtime.evaluate", {
        expression,
        awaitPromise: true,
        returnByValue: true,
        userGesture: true,
        timeout: 15000,
      });
      if (response.exceptionDetails) {
        const d = response.exceptionDetails;
        throw new Error((d.exception && d.exception.description) || d.text || "evaluate failed");
      }
      return response.result ? response.result.value : undefined;
    }
    async waitFor(fn, argument, options) {
      const timeoutMs = (options && options.timeoutMs) || 10000;
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        try {
          if (await this.evaluate(fn, argument)) return;
        } catch (e) {
          if (!contextGone.test(String(e && e.message))) throw e;
        }
        await sleep(Math.min(100, Math.max(0, deadline - Date.now())));
      }
      throw new Error(`Page condition exceeded ${timeoutMs} ms.`);
    }
    async snapshot() {
      const { nodes } = await this.cdp("Accessibility.getFullAXTree", {});
      const info = await this.info();
      return {
        ...info,
        nodes: (nodes || [])
          .filter((n) => !n.ignored && n.backendDOMNodeId)
          .map((n) => ({
            id: n.backendDOMNodeId,
            role: String((n.role && n.role.value) || ""),
            name: String((n.name && n.name.value) || "")
              .replace(/\s+/g, " ")
              .trim(),
            ...(n.value && n.value.value !== undefined && n.value.value !== "" ? { value: String(n.value.value) } : {}),
            ...controlState(n),
          })),
      };
    }
    async clickAt(x, y) {
      if (![x, y].every(Number.isFinite)) throw new Error("Coordinates must be finite.");
      await this.cdp("Input.dispatchMouseEvent", { type: "mouseMoved", x, y });
      await this.cdp("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", clickCount: 1 });
      await this.cdp("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", clickCount: 1 });
    }
    async screenshot(options) {
      const quality = (options && options.quality) || 70;
      const { data } = await this.cdp("Page.captureScreenshot", { format: "jpeg", quality });
      return __longx_image("image/jpeg", data) ? "Screenshot captured." : "Screenshot omitted: at most four per cell.";
    }
    async console(options) {
      await this._ensure();
      return longx("longx.console", { tab: this.id, clear: !!(options && options.clear) });
    }
    async close() {
      if (this.id === null) return;
      await longx("longx.tabs.close", { id: this.id });
      this.id = null;
    }
  }

  const tabs = {
    async open(url) {
      const { tabId } = await longx("longx.tabs.open", {});
      const opened = new Page(tabId);
      globalThis.page = opened;
      if (url && url !== "about:blank") await opened.goto(url);
      return opened;
    },
    list() {
      return longx("longx.tabs.list", {});
    },
    async get(id) {
      const list = await longx("longx.tabs.list", {});
      if (!list.some((t) => t.id === id)) throw new Error(`tab ${id} is not this session's`);
      return new Page(id);
    },
    close(id) {
      return longx("longx.tabs.close", { id });
    },
  };

  globalThis.Page = Page;
  globalThis.tabs = tabs;
  globalThis.page = new Page();
  globalThis.snapshot = () => globalThis.page.snapshot();
  globalThis.screenshot = (options) => globalThis.page.screenshot(options);
  globalThis.sleep = sleep;

  // a little of the web platform the realm lacks (ES2023 only: no DOM, no fetch)
  if (typeof globalThis.URL === "undefined") {
    class URLSearchParams {
      constructor(init) {
        this._list = [];
        const s = typeof init === "string" ? init.replace(/^\?/, "") : "";
        for (const part of s ? s.split("&") : []) {
          const i = part.indexOf("=");
          const k = i < 0 ? part : part.slice(0, i);
          const v = i < 0 ? "" : part.slice(i + 1);
          this._list.push([decodeURIComponent(k.replace(/\+/g, " ")), decodeURIComponent(v.replace(/\+/g, " "))]);
        }
      }
      get(name) {
        const hit = this._list.find(([k]) => k === name);
        return hit ? hit[1] : null;
      }
      getAll(name) {
        return this._list.filter(([k]) => k === name).map(([, v]) => v);
      }
      has(name) {
        return this._list.some(([k]) => k === name);
      }
      set(name, value) {
        this._list = this._list.filter(([k]) => k !== name);
        this._list.push([name, String(value)]);
      }
      append(name, value) {
        this._list.push([name, String(value)]);
      }
      entries() {
        return this._list[Symbol.iterator]();
      }
      [Symbol.iterator]() {
        return this._list[Symbol.iterator]();
      }
      toString() {
        return this._list.map(([k, v]) => encodeURIComponent(k) + "=" + encodeURIComponent(v)).join("&");
      }
    }
    class URL {
      constructor(input, base) {
        let href = String(input);
        if (base !== undefined && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(href)) {
          const b = new URL(base);
          if (href.startsWith("//")) href = b.protocol + href;
          else if (href.startsWith("/")) href = b.origin + href;
          else if (href.startsWith("?")) href = b.origin + b.pathname + href;
          else if (href.startsWith("#")) href = b.origin + b.pathname + b.search + href;
          else href = b.origin + b.pathname.replace(/[^/]*$/, "") + href;
        }
        const m = /^([a-zA-Z][a-zA-Z0-9+.-]*:)(?:\/\/(?:([^@/?#]*)@)?(\[[^\]]*\]|[^:/?#]*)(?::(\d*))?)?([^?#]*)(\?[^#]*)?(#.*)?$/.exec(href);
        if (!m) throw new TypeError("Invalid URL: " + href);
        this.protocol = m[1].toLowerCase();
        const auth = m[2] || "";
        const at = auth.indexOf(":");
        this.username = at < 0 ? auth : auth.slice(0, at);
        this.password = at < 0 ? "" : auth.slice(at + 1);
        this.hostname = (m[3] || "").toLowerCase();
        const defaultPort = { "http:": "80", "https:": "443", "ws:": "80", "wss:": "443" }[this.protocol];
        this.port = m[4] && m[4] !== defaultPort ? m[4] : "";
        this.host = this.hostname + (this.port ? ":" + this.port : "");
        this.pathname = m[5] || (this.hostname ? "/" : "");
        this.search = m[6] && m[6] !== "?" ? m[6] : "";
        this.hash = m[7] && m[7] !== "#" ? m[7] : "";
        this.origin = this.hostname ? this.protocol + "//" + this.host : "null";
        this.searchParams = new URLSearchParams(this.search);
      }
      get href() {
        const auth = this.username ? this.username + (this.password ? ":" + this.password : "") + "@" : "";
        return this.protocol + (this.hostname ? "//" + auth + this.host : "") + this.pathname + this.search + this.hash;
      }
      toString() {
        return this.href;
      }
      toJSON() {
        return this.href;
      }
    }
    globalThis.URL = URL;
    globalThis.URLSearchParams = URLSearchParams;
  }
  if (typeof globalThis.btoa === "undefined") {
    const table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    globalThis.btoa = (s) => {
      let out = "";
      const bytes = [];
      for (const ch of String(s)) {
        const c = ch.codePointAt(0);
        if (c > 255) throw new Error("btoa: character out of Latin1 range");
        bytes.push(c);
      }
      for (let i = 0; i < bytes.length; i += 3) {
        const n = (bytes[i] << 16) | ((bytes[i + 1] || 0) << 8) | (bytes[i + 2] || 0);
        out += table[(n >> 18) & 63] + table[(n >> 12) & 63];
        out += i + 1 < bytes.length ? table[(n >> 6) & 63] : "=";
        out += i + 2 < bytes.length ? table[n & 63] : "=";
      }
      return out;
    };
    globalThis.atob = (s) => {
      const clean = String(s).replace(/[^A-Za-z0-9+/]/g, "");
      let out = "";
      for (let i = 0; i < clean.length; i += 4) {
        const n =
          (table.indexOf(clean[i]) << 18) |
          (table.indexOf(clean[i + 1] || "A") << 12) |
          (table.indexOf(clean[i + 2] || "A") << 6) |
          table.indexOf(clean[i + 3] || "A");
        out += String.fromCharCode((n >> 16) & 255);
        if (clean[i + 2]) out += String.fromCharCode((n >> 8) & 255);
        if (clean[i + 3]) out += String.fromCharCode(n & 255);
      }
      return out;
    };
  }
})();
