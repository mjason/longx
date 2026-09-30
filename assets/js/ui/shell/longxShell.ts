// The bridge to a native shell around the SPA — the Android app (a WebView
// that injects `LongxAndroid.post(json)`), later iOS (`webkit.messageHandlers
// .longx`). Everything is asynchronous JSON in both directions, the smallest
// contract both platforms can implement:
//
//   page → shell   shellPost({type, …})           ready · theme · openExternal · pick
//   shell → page   window.LongxShell.<fn>(…)      back() · navigate(path) · resume() · picked(id, value)
//
// In a plain browser nothing is installed and every call is a no-op.

export type ShellPlatform = "android" | "ios";

export type ShellTheme = { scheme: "dark" | "light"; frame: string; ground: string };

/** A native single-choice list: sections of options, one selected; the answer is `picked(id, optionId | null)`. */
export type ShellPickOption = { id: string; label: string; detail?: string };
export type ShellPickSection = { label?: string; options: ShellPickOption[] };
export type ShellPickRequest = { title: string; sections: ShellPickSection[]; selected: string | null };
/** A renderer-neutral native surface. `data` is JSON-only; actions return through `surfaceResult`. */
export type ShellSurfaceRequest = {
  id: string;
  surface: "menu" | "picker" | "prompt" | "tasks" | "watches";
  title: string;
  placement?: "bottom" | "center" | "anchor";
  data: Record<string, unknown>;
};

export type ShellMessage =
  | { type: "ready"; version: number; theme: ShellTheme }
  | { type: "theme"; theme: ShellTheme }
  | { type: "openExternal"; url: string }
  | ({ type: "pick"; id: string } & ShellPickRequest)
  | ({ type: "surface" } & ShellSurfaceRequest);

export type ShellApi = {
  version: number;
  /** the hardware back key: closes the top layer (dialog / sheet / popover) and returns true, else false */
  back: () => boolean;
  /** a deep link (a notification tapped): an in-app navigation, no reload */
  navigate: (path: string) => void;
  /** back from the background: reconnect and refetch */
  resume: () => void;
  /** the answer to a `pick`: the chosen option's id, null when dismissed */
  picked: (id: string, value: string | null) => void;
  /** Complete a native menu/picker/prompt/popover; value is JSON data owned by that surface. */
  surfaceResult: (id: string, value: unknown) => void;
  /** Native host opts in after implementing the `surface` message contract. */
  setCapabilities: (capabilities: string[]) => void;
};

type AndroidBridge = { post: (json: string) => void };
type IosBridge = { messageHandlers?: { longx?: { postMessage: (json: string) => void } } };

declare global {
  interface Window {
    LongxAndroid?: AndroidBridge;
    webkit?: IosBridge;
    LongxShell?: ShellApi;
  }
}

export const SHELL_VERSION = 2;

export function shellPlatform(): ShellPlatform | null {
  if (typeof window === "undefined") return null;
  if (window.LongxAndroid?.post) return "android";
  if (window.webkit?.messageHandlers?.longx?.postMessage) return "ios";
  return null;
}

export function shellPresent(): boolean {
  return shellPlatform() !== null;
}

export function shellPost(message: ShellMessage): void {
  const json = JSON.stringify(message);
  if (window.LongxAndroid?.post) window.LongxAndroid.post(json);
  else window.webkit?.messageHandlers?.longx?.postMessage(json);
}

/** The colours the shell paints its own bars with: our frame and ground tokens. */
export function readShellTheme(): ShellTheme {
  const root = document.documentElement;
  const styles = getComputedStyle(root);
  const scheme = root.getAttribute("data-theme") === "light" ? "light" : "dark";
  return {
    scheme,
    frame: styles.getPropertyValue("--sidebar").trim(),
    ground: styles.getPropertyValue("--background").trim(),
  };
}

// Radix layers (dialogs, sheets, popovers, menus) close on Escape; an open
// one is the thing a back key should dismiss before leaving the page
const OPEN_LAYER = '[role="dialog"][data-state="open"], [data-radix-popper-content-wrapper], [role="menu"][data-state="open"]';

export function closeTopLayer(): boolean {
  if (!document.querySelector(OPEN_LAYER)) return false;
  const target = document.activeElement ?? document.body;
  target.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
  return true;
}

const picks = new Map<string, (value: string | null) => void>();
const surfaces = new Map<string, (value: unknown) => void>();
let pickSeq = 0;
let surfaceSeq = 0;
let nativeCapabilities = new Set<string>();

/**
 * Asks the shell for a native single-choice list (a bottom sheet on Android)
 * — a popover is a poor fit for a phone. Resolves with the option picked,
 * null when dismissed. Only meaningful while a shell is present.
 */
export function shellPick(request: ShellPickRequest): Promise<string | null> {
  const id = `pick-${++pickSeq}`;
  return new Promise((resolve) => {
    picks.set(id, resolve);
    shellPost({ type: "pick", id, ...request });
  });
}

function picked(id: string, value: string | null): void {
  const resolve = picks.get(id);
  if (!resolve) return;
  picks.delete(id);
  resolve(value);
}

/** Requests a native UI surface; null means no shell is installed or it dismissed it. */
export function shellSurface(request: Omit<ShellSurfaceRequest, "id">): Promise<unknown | null> {
  if (!shellCanRenderSurface()) return Promise.resolve(null);
  const id = `surface-${++surfaceSeq}`;
  return new Promise((resolve) => {
    surfaces.set(id, resolve);
    shellPost({ type: "surface", id, ...request });
  });
}

export function shellCanRenderSurface(): boolean {
  return shellPresent() && nativeCapabilities.has("surfaces");
}

function surfaceResult(id: string, value: unknown): void {
  const resolve = surfaces.get(id);
  if (!resolve) return;
  surfaces.delete(id);
  resolve(value);
}

export type ShellHandlers = {
  navigate: (path: string) => void;
  resume: () => void;
};

/**
 * Installs the page's half of the bridge when a shell is present: marks
 * `<html data-shell>`, exposes `window.LongxShell`, keeps `--app-height` at
 * the visual viewport's height (the keyboard shrinks it — the WebView does
 * not always resize the layout viewport), sends links to other hosts to the
 * shell, and posts `ready`. Returns the uninstall.
 */
export function installShell(handlers: ShellHandlers): () => void {
  const platform = shellPlatform();
  if (!platform) return () => {};
  nativeCapabilities = new Set();
  const root = document.documentElement;
  root.setAttribute("data-shell", platform);

  window.LongxShell = {
    version: SHELL_VERSION,
    back: closeTopLayer,
    navigate: handlers.navigate,
    resume: handlers.resume,
    picked,
    surfaceResult,
    setCapabilities: (capabilities) => { nativeCapabilities = new Set(capabilities); },
  };

  const vv = window.visualViewport;
  const setHeight = () => {
    if (vv) root.style.setProperty("--app-height", `${Math.round(vv.height)}px`);
  };
  setHeight();
  vv?.addEventListener("resize", setHeight);

  const onClick = (event: MouseEvent) => {
    const anchor = (event.target as Element | null)?.closest?.("a[href]");
    if (!anchor) return;
    const url = new URL((anchor as HTMLAnchorElement).href, location.href);
    if (url.origin === location.origin) return;
    event.preventDefault();
    shellPost({ type: "openExternal", url: url.href });
  };
  document.addEventListener("click", onClick);

  shellPost({ type: "ready", version: SHELL_VERSION, theme: readShellTheme() });

  return () => {
    document.removeEventListener("click", onClick);
    vv?.removeEventListener("resize", setHeight);
    root.style.removeProperty("--app-height");
    root.removeAttribute("data-shell");
    delete window.LongxShell;
    nativeCapabilities = new Set();
  };
}
