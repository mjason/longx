// Shared vi.mock factories for screen tests: a fake RPC client and socket.
import { vi } from "vitest";

export const ok = <T,>(data: T) => ({ success: true as const, data });
export const failed = (message: string, fields: string[] = []) => ({
  success: false as const,
  errors: [{ type: "invalid", message, shortMessage: message, vars: {}, fields, path: [], details: {} }],
});

export const project = (n: number) => ({
  id: `id-${n}`, slug: `app-${n}`, name: `App ${n}`, description: null, rootPath: `/srv/app-${n}`,
  sandbox: "workspace_write", approvalPolicy: "on_request", networkAccess: false, dirtyStart: "commit",
  tools: [], memoryLimitMb: null, archivedAt: null, updatedAt: "2026-09-12T00:00:00Z",
});

export const thread = (n: number) => ({
  id: `t${n}`, codexThreadId: `thr_${n}`, title: null, preview: `thread ${n}`, status: "idle", modelSlug: null,
  lastActivityAt: "2026-09-12T00:00:00Z", insertedAt: "2026-09-12T00:00:00Z",
});

export function rpcMock() {
  return {
    listProjects: vi.fn(async () => ok([project(1), project(2)])),
    getProject: vi.fn(async () => ok(project(1))),
    createProject: vi.fn(),
    gitInfo: vi.fn(async () => ok({ repository: true, head: "372bb0366a5ae41b", clean: true, changes: 0, lfs: false })),
    initGit: vi.fn(),
    codexInfo: vi.fn(async () => ok({ home: "/x", exists: false, bytes: 0, files: {}, worker: null })),
    listThreads: vi.fn(async () => ok([thread(1)])),
    startThread: vi.fn(async () => ok(thread(2))),
    stopCodex: vi.fn(),
    restartCodex: vi.fn(),
    sandboxStatus: vi.fn(async () => ok({ status: "ok", reason: null, checkedAt: "" })),
    listDirectory: vi.fn(async ({ input }: { input?: { path?: string; showHidden?: boolean } }) => {
      const path = input?.path ?? "/home/me";
      const entries =
        path === "/home/me"
          ? [{ name: "code", path: "/home/me/code", git: false }, { name: "repo", path: "/home/me/repo", git: true }]
          : path === "/home/me/code"
            ? [{ name: "my-app", path: "/home/me/code/my-app", git: false }]
            : [];
      const hidden = input?.showHidden && path === "/home/me" ? [{ name: ".dotfiles", path: "/home/me/.dotfiles", git: true }] : [];
      return ok({ path, parent: path === "/" ? null : path.split("/").slice(0, -1).join("/") || "/", git: path === "/home/me/repo", entries: [...hidden, ...entries], roots: [{ name: "me", path: "/home/me", git: false }, { name: "/", path: "/", git: false }] });
    }),
  };
}

export const channel = { on: vi.fn(), join: vi.fn(), leave: vi.fn() };
export function socketMock(status: "open" | "closed" = "open") {
  return { socketStatus: () => status, onSocketStatus: () => () => {}, getSocket: () => ({ channel: () => channel }) };
}
