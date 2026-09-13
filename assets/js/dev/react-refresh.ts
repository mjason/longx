// Dev only. Vite's React plugin expects its Fast Refresh preamble to run
// before any component module; Vite's own index.html would inject it, our
// page is served by Phoenix (LongxWeb.Vite loads this module first).
// https://vite.dev/guide/backend-integration
// @ts-expect-error — a virtual module only the Vite dev server serves
import RefreshRuntime from "/@react-refresh";

RefreshRuntime.injectIntoGlobalHook(window);
(window as unknown as Record<string, unknown>).$RefreshReg$ = () => {};
(window as unknown as Record<string, unknown>).$RefreshSig$ = () => (type: unknown) => type;
(window as unknown as Record<string, unknown>).__vite_plugin_react_preamble_installed__ = true;
