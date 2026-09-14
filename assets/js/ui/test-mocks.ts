// Shared vi.mock factories for screen tests: a fake RPC client and socket.
import { vi } from "vitest";

export const ok = <T,>(data: T) => ({ success: true as const, data });
export const failed = (message: string, fields: string[] = []) => ({
  success: false as const,
  errors: [{ type: "invalid", message, shortMessage: message, vars: {}, fields, path: [], details: {} }],
});

export const project = (n: number) => ({
  id: `id-${n}`, slug: `app-${n}`, name: `App ${n}`, description: null, rootPath: `/srv/app-${n}`,
  sandbox: "workspace_write", approvalPolicy: "on_request", networkAccess: false, webSearch: true, multiAgent: true, dirtyStart: "commit",
  tools: [], memoryLimitMb: null, archivedAt: null, updatedAt: "2026-09-12T00:00:00Z",
});

export const thread = (n: number) => ({
  id: `t${n}`, codexThreadId: `thr_${n}`, title: null, preview: `thread ${n}`, status: "idle", modelSlug: null,
  sandbox: "workspace_write", approvalPolicy: "on_request", networkAccess: false, webSearch: true, multiAgent: true,
  lastActivityAt: "2026-09-12T00:00:00Z", insertedAt: "2026-09-12T00:00:00Z",
});

export function rpcMock() {
  return {
    listProjects: vi.fn(async () => ok([project(1), project(2)])),
    getProject: vi.fn(async () => ok(project(1))),
    createProject: vi.fn(),
    updateProject: vi.fn(async () => ok(project(1))),
    archiveProject: vi.fn(async () => ok(project(1))),
    clearCodexHistory: vi.fn(async () => ok(null)),
    gitInfo: vi.fn(async () => ok({ repository: true, head: "372bb0366a5ae41b", clean: true, changes: 0, lfs: false })),
    initGit: vi.fn(),
    codexInfo: vi.fn(async () => ok({ home: "/x", exists: false, bytes: 0, files: {}, worker: null, stale: [] })),
    listThreads: vi.fn(async () => ok([thread(1)])),
    listModels: vi.fn(async () => ok([model(1, { slug: "deepseek-flash", default: true }), model(2, { slug: "glm-5" })])),
    sendMessage: vi.fn(async () => ok({ id: "turn-row" })),
    compactThread: vi.fn(async () => ok(null)),
    reviewThread: vi.fn(async () => ok({ id: "turn-review" })),
    interruptTurn: vi.fn(async () => ok(null)),
    respond: vi.fn(async () => ok(null)),
    answerRequest: vi.fn(async () => ok(null)),
    deleteThread: vi.fn(async () => ok(null)),
    listTurns: vi.fn(async () => ok([])),
    listSubagents: vi.fn(async () => ok([])),
    searchFiles: vi.fn(async () => ok([])),
    listFiles: vi.fn(async () => ok([])),
    readFile: vi.fn(async () => ok({ path: "", content: "", size: 0, binary: false, truncated: false })),
    writeFile: vi.fn(async () => ok(null)),
    createEntry: vi.fn(async ({ input }: { input: { path: string; kind: string } }) => ok({ name: input.path.split("/").at(-1), path: input.path, kind: input.kind, size: 0 })),
    renameEntry: vi.fn(async ({ input }: { input: { to: string } }) => ok({ name: input.to.split("/").at(-1), path: input.to, kind: "file", size: 0 })),
    deleteEntry: vi.fn(async () => ok(null)),
    gitChanges: vi.fn(async () => ok({ repository: false, branch: null, head: null, changes: [], ahead: null, behind: null, remotes: [], lfs: false, ignored: [], merging: false })),
    gitAbortMerge: vi.fn(async () => ok(null)),
    gitFileVersions: vi.fn(async () => ok({ before: "one\n", after: "two\n", binary: false })),
    gitCommit: vi.fn(async () => ok({ sha: "c0ffee" })),
    gitDiscard: vi.fn(async () => ok(null)),
    gitUndoCommit: vi.fn(async () => ok({ sha: "abc" })),
    gitLog: vi.fn(async () => ok([])),
    gitShow: vi.fn(async () => ok({ sha: "", subject: "", body: "", author: "", email: "", at: "", parents: [], files: [] })),
    gitBranches: vi.fn(async () => ok({ current: "main", branches: [{ name: "main", sha: "abc", current: true, upstream: null }], stashes: [] })),
    gitCreateBranch: vi.fn(async () => ok(null)),
    gitSwitch: vi.fn(async () => ok(null)),
    gitDeleteBranch: vi.fn(async () => ok(null)),
    gitStashPop: vi.fn(async () => ok(null)),
    gitSetRemote: vi.fn(async () => ok(null)),
    gitFetch: vi.fn(async () => ok(null)),
    gitPull: vi.fn(async () => ok(null)),
    gitPush: vi.fn(async () => ok(null)),
    restoreProposal: vi.fn(async () => ok({ commit: "aaaa1111", dirtyNow: false, changedFiles: [], laterTurns: 0 })),
    restoreFiles: vi.fn(async () => ok({ safetyCommit: null, head: "aaaa1111" })),
    redoTurn: vi.fn(async () => ok({ id: "tu9", threadId: "t1" })),
    renameThread: vi.fn(async () => ok(thread(1))),
    archiveThread: vi.fn(async () => ok(thread(1))),
    startThread: vi.fn(async () => ok(thread(2))),
    stopCodex: vi.fn(),
    restartCodex: vi.fn(),
    sandboxStatus: vi.fn(async () => ok({ status: "ok", reason: null, checkedAt: "" })),
    createDirectory: vi.fn(async ({ input }: { input: { parent: string; name: string } }) => ok({ name: input.name, path: `${input.parent}/${input.name}`, git: false })),
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

export const model = (n: number, extra: Partial<{ slug: string; default: boolean; name: string }> = {}) => ({
  id: `m${n}`, name: extra.name ?? `Model ${n}`, slug: extra.slug ?? `model-${n}`, default: extra.default ?? n === 1,
  reasoningEffort: n === 1 ? "medium" : null, provider: { name: "Prov" },
});

/**
 * A channel double that remembers what was joined and lets a test deliver
 * the join reply (`channel.reply("ok", snapshot)`) and deliver server pushes
 * (`channel.deliver("codex", event)`) — for both the project and thread
 * topics; the shared maps hold the most recent join, `replyTo` / `deliverTo`
 * address one topic when several threads are open (a thread and its
 * sub-agents). Client pushes (`push`) are recorded; `answer(status, payload)`
 * resolves the last one.
 */
type TopicState = { handlers: Record<string, (payload: unknown) => void>; replies: Record<string, (payload: unknown) => void> };

export const channel = {
  topics: [] as string[],
  byTopic: {} as Record<string, TopicState>,
  handlers: {} as Record<string, (payload: unknown) => void>,
  replies: {} as Record<string, (payload: unknown) => void>,
  on: vi.fn((event: string, cb: (payload: unknown) => void) => {
    channel.handlers[event] = cb;
  }),
  join: vi.fn(() => {
    const receiver = {
      receive(status: string, cb: (payload: unknown) => void) {
        channel.replies[status] = cb;
        return receiver;
      },
    };
    return receiver;
  }),
  leave: vi.fn(),
  pushed: [] as { event: string; payload: unknown }[],
  pushReplies: {} as Record<string, (payload: unknown) => void>,
  push: vi.fn((event: string, payload: unknown) => {
    channel.pushed.push({ event, payload });
    const receiver = {
      receive(status: string, cb: (payload: unknown) => void) {
        channel.pushReplies[status] = cb;
        return receiver;
      },
    };
    return receiver;
  }),
  reply(status: string, payload: unknown) {
    channel.replies[status]?.(payload);
  },
  replyTo(topic: string, status: string, payload: unknown) {
    channel.byTopic[topic]?.replies[status]?.(payload);
  },
  answer(status: string, payload: unknown) {
    channel.pushReplies[status]?.(payload);
  },
  deliver(event: string, payload: unknown) {
    channel.handlers[event]?.(payload);
  },
  deliverTo(topic: string, event: string, payload: unknown) {
    channel.byTopic[topic]?.handlers[event]?.(payload);
  },
  reset() {
    channel.topics = [];
    channel.byTopic = {};
    channel.handlers = {};
    channel.replies = {};
    channel.pushed = [];
    channel.pushReplies = {};
    channel.push.mockClear();
    channel.on.mockClear();
    channel.join.mockClear();
    channel.leave.mockClear();
  },
};

// one topic's view of the shared double: records into both
function topicChannel(topic: string) {
  const state: TopicState = { handlers: {}, replies: {} };
  channel.byTopic[topic] = state;
  return {
    on: (event: string, cb: (payload: unknown) => void) => {
      state.handlers[event] = cb;
      channel.on(event, cb);
    },
    join: () => {
      const shared = channel.join();
      const receiver = {
        receive(status: string, cb: (payload: unknown) => void) {
          state.replies[status] = cb;
          shared.receive(status, cb);
          return receiver;
        },
      };
      return receiver;
    },
    leave: channel.leave,
    push: channel.push,
  };
}

export function socketMock(status: "open" | "closed" = "open") {
  return {
    socketStatus: () => status,
    onSocketStatus: () => () => {},
    getSocket: () => ({
      channel: (topic: string) => {
        channel.topics.push(topic);
        return topicChannel(topic);
      },
    }),
  };
}
