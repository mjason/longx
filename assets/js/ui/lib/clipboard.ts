// Copying on a LAN address. Longx is reached over plain http
// (http://192.168.x.x:7788) — not a secure context, so the browser gives the
// page no `navigator.clipboard` and every copy button (a code block's, a
// message's) silently did nothing. The old way still works there: select a
// scratch textarea and `execCommand("copy")`.

/** Copies text: the Clipboard API when the page has it, the selection way otherwise. */
export async function copyText(text: string): Promise<void> {
  const api = (navigator as { clipboard?: { writeText?: (t: string) => Promise<void> } }).clipboard;
  if (api?.writeText && api.writeText !== fallbackWriteText) {
    try {
      await api.writeText(text);
      return;
    } catch {
      // fall through: some browsers expose the API and then refuse it
    }
  }
  if (!copyBySelection(text)) throw new Error("clipboard unavailable");
}

function copyBySelection(text: string): boolean {
  if (typeof document === "undefined" || typeof document.execCommand !== "function") return false;
  const area = document.createElement("textarea");
  area.value = text;
  area.setAttribute("readonly", "");
  area.style.position = "fixed";
  area.style.top = "0";
  area.style.left = "0";
  area.style.opacity = "0";
  document.body.appendChild(area);
  const active = document.activeElement as HTMLElement | null;
  try {
    area.focus();
    area.select();
    area.setSelectionRange(0, text.length);
    return document.execCommand("copy");
  } catch {
    return false;
  } finally {
    area.remove();
    active?.focus?.();
  }
}

async function fallbackWriteText(text: string): Promise<void> {
  if (!copyBySelection(text)) throw new Error("clipboard unavailable");
}

/**
 * Gives an insecure page a `navigator.clipboard.writeText` built on the
 * selection way, so assistant-ui's own copy button and every library that
 * asks for the API work over plain http. A real Clipboard API is left as it is.
 */
export function installClipboardFallback(): void {
  if (typeof navigator === "undefined") return;
  const nav = navigator as { clipboard?: unknown };
  if (nav.clipboard) return;
  try {
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText: fallbackWriteText },
      configurable: true,
    });
  } catch {
    // a frozen navigator: copyText still has the fallback itself
  }
}
