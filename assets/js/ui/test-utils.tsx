import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render } from "@testing-library/react";
import { createMemoryRouter, RouterProvider } from "react-router";
import { routes } from "./routes";

/** Renders the real route tree at `path` with a fresh query client. */
export function renderAt(path: string) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const router = createMemoryRouter(routes, { initialEntries: [path] });
  return { router, ...render(<QueryClientProvider client={client}><RouterProvider router={router} /></QueryClientProvider>) };
}

/** Phone or desktop viewport for a test. */
export function setViewport(width: number) {
  Object.defineProperty(window, "innerWidth", { configurable: true, value: width });
  window.dispatchEvent(new Event("resize"));
}

export const ok = <T,>(data: T) => ({ success: true as const, data });
export const failed = (message: string, fields: string[] = []) => ({
  success: false as const,
  errors: [{ type: "invalid", message, shortMessage: message, vars: {}, fields, path: [], details: {} }],
});
