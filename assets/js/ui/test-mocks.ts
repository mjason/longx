// Shared vi.mock factories for screen tests: a fake RPC client and socket.
import { vi } from "vitest";

export const ok = <T>(data: T) => ({ success: true as const, data });
export const failed = (message: string, fields: string[] = []) => ({
  success: false as const,
  errors: [
    {
      type: "invalid",
      message,
      shortMessage: message,
      vars: {},
      fields,
      path: [],
      details: {},
    },
  ],
});

export const dependencyTool = (name: string, extra: Record<string, unknown> = {}) => ({
  name,
  command: name,
  found: true,
  path: `/usr/bin/${name}`,
  version: "1.0.0",
  install: { apt: name, brew: name, winget: null },
  ...extra,
});

/** every tool found: the strip shows nothing */
export const dependencyReport = (extra: Record<string, unknown> = {}) => ({
  os: "linux",
  missing: 0,
  installCommand: null,
  tools: ["ripgrep", "fd-find", "fzf", "bat", "jq", "tree", "git", "gh", "git-delta"].map((n) => dependencyTool(n)),
  checkedAt: "2026-09-18T00:00:00Z",
  ...extra,
});

/** a credential row as the wire lists it: never a value, only "has one" */
export const credential = (name: string, extra: Record<string, unknown> = {}) => ({
  id: `cred-${name}`,
  name,
  label: null,
  kind: "api_key",
  header: "authorization",
  scheme: "Bearer",
  allowedHosts: ["api.example.com"],
  clientId: null,
  authorizeUrl: null,
  tokenUrl: null,
  registrationUrl: null,
  scopes: null,
  pkce: true,
  expiresAt: null,
  refreshedAt: null,
  lastError: null,
  status: "ready",
  hasSecret: true,
  hasAccessToken: false,
  hasRefreshToken: false,
  hasClientSecret: false,
  ...extra,
});

export const agentSettingsData = () => ({
  maxDepth: 2,
  maxChildren: 4,
  idleMinutes: 30,
  childModel: null,
  childEffort: null,
});

export const agentDefinitionData = (extra: Record<string, unknown> = {}) => ({
  present: false,
  trusted: false,
  dir: "/srv/app-1/.longx",
  model: null,
  effort: null,
  plugs: [],
  files: [],
  localFiles: [],
  agents: [
    { name: "coder", summary: "implements a bounded task", layer: "project" },
    { name: "researcher", summary: "searches the web", layer: "local" },
  ],
  settings: agentSettingsData(),
  overrides: {},
  errors: [],
  ...extra,
});

export const project = (n: number) => ({
  id: `id-${n}`,
  slug: `app-${n}`,
  name: `App ${n}`,
  description: null,
  rootPath: `/srv/app-${n}`,
  webSearch: true,
  dirtyStart: "commit",
  modelId: null,
  trustLocalAgent: false,
  agentSettings: null,
  archivedAt: null,
  updatedAt: "2026-09-12T00:00:00Z",
});

export const thread = (n: number) => ({
  id: `t${n}`,
  kernelThreadId: `thr_${n}`,
  title: null,
  preview: `thread ${n}`,
  status: "idle",
  modelSlug: null,
  reasoningEffort: null,
  webSearch: true,
  lastActivityAt: "2026-09-12T00:00:00Z",
  insertedAt: "2026-09-12T00:00:00Z",
});

export const browserIdle = {
  stage: "idle",
  received: 0,
  total: null as number | null,
  error: null as string | null,
  version: "0.2.2",
  latest: "0.2.2",
  target: "x86_64-linux",
  path: null as string | null,
  source: null as "env" | "downloaded" | null,
  installedVersion: null as string | null,
  upgradable: false,
};

export const upgradeIdle = {
  current: "0.1.0",
  installed: true,
  latest: null as string | null,
  available: false,
  notesUrl: null as string | null,
  checkedAt: null as string | null,
  error: null as string | null,
  stage: "idle" as const,
  message: null as string | null,
  target: null as string | null,
  progress: null as { received: number; total: number | null } | null,
  hasGithubToken: false,
};

export function rpcMock() {
  return {
    listProjects: vi.fn(async () => ok([project(1), project(2)])),
    listRunningThreads: vi.fn(async () => ok({ threads: [] })),
    getProject: vi.fn(async () => ok(project(1))),
    createProject: vi.fn(),
    updateProject: vi.fn(async () => ok(project(1))),
    archiveProject: vi.fn(async () => ok(project(1))),
    deleteProject: vi.fn(async () => ok(null)),
    gitInfo: vi.fn(async () =>
      ok({
        repository: true,
        head: "372bb0366a5ae41b",
        clean: true,
        changes: 0,
        lfs: false,
      }),
    ),
    initGit: vi.fn(),
    listThreads: vi.fn(async () => ok([thread(1)])),
    getThread: vi.fn(async ({ input }: { input: { id: string } }) => ok({ ...thread(1), id: input.id })),
    listModels: vi.fn(async () =>
      ok([
        model(1, { slug: "deepseek-flash", default: true }),
        model(2, { slug: "glm-5", reasoningLevels: ["low", "high"] }),
      ]),
    ),
    modelAliases: vi.fn(async () =>
      ok([
        { name: "ultra", label: "旗舰", models: ["glm-5", "deepseek-flash"], builtin: true },
        { name: "pro", label: "高级", models: [], builtin: true },
        { name: "plus", label: "普通", models: [], builtin: true },
      ]),
    ),
    setModelAlias: vi.fn(async ({ input }: { input: { name: string; models: string[] } }) => ok({ name: input.name, label: input.name, models: input.models, builtin: false })),
    deleteModelAlias: vi.fn(async () => ok(null)),
    discoverModels: vi.fn(async () => ok({ ok: true, error: null, models: [] })),
    setGoal: vi.fn(async ({ input }: { input: Record<string, unknown> }) =>
      ok({ objective: input["objective"] ?? "", status: input["status"] ?? "active", tokenBudget: input["tokenBudget"] ?? null, tokensUsed: 0, timeUsedSeconds: 0 }),
    ),
    clearGoal: vi.fn(async () => ok({ cleared: true })),
    agentDefinition: vi.fn(async () => ok(agentDefinitionData())),
    promoteLocal: vi.fn(async ({ input }: { input: { path: string } }) => ok({ path: `shared/${input.path}` })),
    agentSettings: vi.fn(async () => ok(agentSettingsData())),
    setAgentSettings: vi.fn(async ({ input }: { input: Record<string, unknown> }) => ok({ ...agentSettingsData(), ...input })),
    publicUrl: vi.fn(async () => ok({ url: "http://192.168.2.129:7788", setting: null })),
    dependencies: vi.fn(async () => ok(dependencyReport())),
    checkDependencies: vi.fn(async () => ok(dependencyReport())),
    listCredentials: vi.fn(async () => ok([credential("svc"), credential("coros", { kind: "oauth2", status: "needs_login", hasSecret: false, clientId: "47c53db0", allowedHosts: ["mcp.coros.com", "mcpcn.coros.com"], authorizeUrl: "https://mcpcn.coros.com/oauth2/authorize", tokenUrl: "https://mcpcn.coros.com/oauth2/token", scopes: "openid mcp.tools" })])),
    createCredentialApiKey: vi.fn(async ({ input }: { input: Record<string, unknown> }) => ok(credential(String(input["name"]), input as never))),
    createCredentialOauth2: vi.fn(async ({ input }: { input: Record<string, unknown> }) => ok(credential(String(input["name"]), { kind: "oauth2", status: "needs_login", ...(input as object) } as never))),
    updateCredential: vi.fn(async ({ input }: { input: Record<string, unknown> }) => ok(credential("svc", input as never))),
    deleteCredential: vi.fn(async () => ok(null)),
    credentialLoginUrl: vi.fn(async () => ok({ url: "https://auth.example/authorize?state=s1", redirectUri: "http://127.0.0.1:7798/callback/credentials", loopback: true })),
    credentialCompleteUrl: vi.fn(async () => ok(credential("coros", { kind: "oauth2", status: "ready" }))),
    refreshCredential: vi.fn(async () => ok(credential("coros", { kind: "oauth2", status: "ready", hasAccessToken: true, hasRefreshToken: true }))),
    credentialRedirectUri: vi.fn(async () => ok({ uri: "http://localhost:3000/callback/credentials" })),
    setPublicUrl: vi.fn(async ({ input }: { input: { url: string } }) => ok({ url: input.url || "http://192.168.2.129:7788", setting: input.url || null })),
    listProviders: vi.fn(async () => ok([provider(1), provider(2)])),
    createProvider: vi.fn(
      async ({ input }: { input: Record<string, unknown> }) =>
        ok(provider(3, input)),
    ),
    updateProvider: vi.fn(
      async ({ input }: { input: Record<string, unknown> }) =>
        ok(provider(1, input)),
    ),
    deleteProvider: vi.fn(async () => ok(null)),
    createModel: vi.fn(async ({ input }: { input: Record<string, unknown> }) =>
      ok(model(3, input as never)),
    ),
    updateModel: vi.fn(async ({ input }: { input: Record<string, unknown> }) =>
      ok(model(2, input as never)),
    ),
    deleteModel: vi.fn(async () => ok(null)),
    makeDefaultModel: vi.fn(async () => ok(model(2, { default: true }))),
    checkModel: vi.fn(async () =>
      ok({ ok: true, latencyMs: 321, error: null }),
    ),
    listSearchProviders: vi.fn(async () =>
      ok([
        {
          id: "s1",
          name: "Tavily",
          slug: "tavily",
          kind: "tavily",
          baseUrl: null,
          hasApiKey: false,
          default: true,
        },
      ]),
    ),
    updateSearchProvider: vi.fn(async () => ok({ id: "s1", hasApiKey: true })),
    listPresets: vi.fn(async () => ok(presets())),
    applyPreset: vi.fn(async () => ok({ providerId: "p9", modelIds: ["m9"] })),
    gatewayRequests: vi.fn(async () =>
      ok({
        keep: 1000,
        requests: [
          { id: 2, at: "2026-09-16T10:00:05Z", threadId: "thr_1", turnId: "turn_1", requestKind: "agent", model: "deepseek-flash", upstreamId: "deepseek-v4-flash", provider: "deepseek", effort: "low", summary: "auto", tools: ["exec_command", "memory"], inputItems: 12, inputChars: 4000, instructionsChars: 900, maxOutputTokens: 4096, status: 200, durationMs: 1234, error: null },
          { id: 1, at: "2026-09-16T10:00:00Z", threadId: null, turnId: null, requestKind: null, model: "nope", upstreamId: null, provider: null, effort: null, summary: null, tools: [], inputItems: 0, inputChars: 2, instructionsChars: 0, maxOutputTokens: null, status: 400, durationMs: 1, error: "unknown model \"nope\"" },
        ],
      }),
    ),
    browserSettings: vi.fn(async () => ok({ allowPrivateNetwork: false, available: true })),
    browserStatus: vi.fn(async () => ok({ ...browserIdle, stage: "installed", path: "/data/obscura/0.2.2/x86_64-linux/obscura" })),
    browserInstall: vi.fn(async () => ok({ ...browserIdle, stage: "downloading", received: 0, total: 60_000_000 })),
    setBrowserPrivateNetwork: vi.fn(async ({ input }: { input: { enabled: boolean } }) => ok({ allowPrivateNetwork: input.enabled, available: true })),
    knowledgeDocs: vi.fn(async () =>
      ok([
        { root: "longx", path: "longx/writing-plugs.md", title: "Writing plugs", summary: "the plug API", tags: ["longx"], always: false, writable: false },
        { root: "global", path: "global/me.md", title: "About me", summary: "how I like things", tags: ["me"], always: true, writable: true },
      ]),
    ),
    knowledgeRead: vi.fn(async () => ok({ text: "---\ntitle: About me\nsummary: how I like things\ntags: [me]\nalways: true\n---\nTabs, never spaces.\n" })),
    knowledgeWrite: vi.fn(async () => ok(null)),
    knowledgeDelete: vi.fn(async () => ok(null)),
    upgradeStatus: vi.fn(async () => ok(upgradeIdle)),
    upgradeCheck: vi.fn(async () =>
      ok({
        ...upgradeIdle,
        latest: "0.2.0",
        available: true,
        notesUrl: "https://github.com/mjason/longx/releases/tag/v0.2.0",
        checkedAt: "2026-09-14T08:00:00Z",
      }),
    ),
    upgradeApply: vi.fn(async () =>
      ok({ ...upgradeIdle, latest: "0.2.0", available: true, stage: "downloading", target: "0.2.0" }),
    ),
    setGithubToken: vi.fn(async ({ input }: { input: { token?: string | null } }) =>
      ok({ ...upgradeIdle, hasGithubToken: !!input.token }),
    ),
    sendMessage: vi.fn(async () => ok({ id: "turn-row" })),
    compactThread: vi.fn(async () => ok(null)),
    interruptTurn: vi.fn(async () => ok(null)),
    retractTurn: vi.fn(async () => ok({ text: "look at pandas" })),
    steerTurn: vi.fn(async () => ok({ kernelTurnId: "turn_2" })),
    answerRequest: vi.fn(async () => ok(null)),
    deleteThread: vi.fn(async () => ok(null)),
    listTurns: vi.fn(async () => ok([])),
    listSubagents: vi.fn(async () => ok([])),
    searchFiles: vi.fn(async () => ok([])),
    listFiles: vi.fn(async () => ok([])),
    readFile: vi.fn(async () =>
      ok({ path: "", content: "", size: 0, binary: false, truncated: false }),
    ),
    writeFile: vi.fn(async () => ok(null)),
    createEntry: vi.fn(
      async ({ input }: { input: { path: string; kind: string } }) =>
        ok({
          name: input.path.split("/").at(-1),
          path: input.path,
          kind: input.kind,
          size: 0,
        }),
    ),
    renameEntry: vi.fn(async ({ input }: { input: { to: string } }) =>
      ok({
        name: input.to.split("/").at(-1),
        path: input.to,
        kind: "file",
        size: 0,
      }),
    ),
    deleteEntry: vi.fn(async () => ok(null)),
    gitChanges: vi.fn(async () =>
      ok({
        repository: false,
        branch: null,
        head: null,
        changes: [],
        ahead: null,
        behind: null,
        remotes: [],
        lfs: false,
        ignored: [],
        merging: false,
      }),
    ),
    gitAbortMerge: vi.fn(async () => ok(null)),
    gitFileVersions: vi.fn(async () =>
      ok({ before: "one\n", after: "two\n", binary: false }),
    ),
    gitCommit: vi.fn(async () => ok({ sha: "c0ffee" })),
    gitDiscard: vi.fn(async () => ok(null)),
    gitUndoCommit: vi.fn(async () => ok({ sha: "abc" })),
    gitLog: vi.fn(async () => ok([])),
    gitShow: vi.fn(async () =>
      ok({
        sha: "",
        subject: "",
        body: "",
        author: "",
        email: "",
        at: "",
        parents: [],
        files: [],
      }),
    ),
    gitBranches: vi.fn(async () =>
      ok({
        current: "main",
        branches: [{ name: "main", sha: "abc", current: true, upstream: null }],
        stashes: [],
      }),
    ),
    gitCreateBranch: vi.fn(async () => ok(null)),
    gitSwitch: vi.fn(async () => ok(null)),
    gitDeleteBranch: vi.fn(async () => ok(null)),
    gitStashPop: vi.fn(async () => ok(null)),
    gitSetRemote: vi.fn(async () => ok(null)),
    gitFetch: vi.fn(async () => ok(null)),
    gitPull: vi.fn(async () => ok(null)),
    gitPush: vi.fn(async () => ok(null)),
    restoreProposal: vi.fn(async () =>
      ok({
        commit: "aaaa1111",
        dirtyNow: false,
        changedFiles: [],
        laterTurns: 0,
      }),
    ),
    restoreFiles: vi.fn(async () =>
      ok({ safetyCommit: null, head: "aaaa1111" }),
    ),
    renameThread: vi.fn(async () => ok(thread(1))),
    archiveThread: vi.fn(async () => ok(thread(1))),
    startThread: vi.fn(async () => ok(thread(2))),
    createDirectory: vi.fn(
      async ({ input }: { input: { parent: string; name: string } }) =>
        ok({
          name: input.name,
          path: `${input.parent}/${input.name}`,
          git: false,
        }),
    ),
    listDirectory: vi.fn(
      async ({
        input,
      }: {
        input?: { path?: string; showHidden?: boolean };
      }) => {
        const path = input?.path ?? "/home/me";
        const entries =
          path === "/home/me"
            ? [
                { name: "code", path: "/home/me/code", git: false },
                { name: "repo", path: "/home/me/repo", git: true },
              ]
            : path === "/home/me/code"
              ? [{ name: "my-app", path: "/home/me/code/my-app", git: false }]
              : [];
        const hidden =
          input?.showHidden && path === "/home/me"
            ? [{ name: ".dotfiles", path: "/home/me/.dotfiles", git: true }]
            : [];
        return ok({
          path,
          parent:
            path === "/" ? null : path.split("/").slice(0, -1).join("/") || "/",
          git: path === "/home/me/repo",
          entries: [...hidden, ...entries],
          roots: [
            { name: "me", path: "/home/me", git: false },
            { name: "/", path: "/", git: false },
          ],
        });
      },
    ),
  };
}

export const model = (
  n: number,
  extra: Partial<{
    slug: string;
    default: boolean;
    name: string;
    upstreamId: string;
    providerId: string;
    contextWindow: number | null;
    reasoningLevels: string[];
    reasoningEffort: string | null;
  }> = {},
) => ({
  id: `m${n}`,
  name: extra.name ?? `Model ${n}`,
  slug: extra.slug ?? `model-${n}`,
  upstreamId: extra.upstreamId ?? `upstream-${n}`,
  default: extra.default ?? n === 1,
  contextWindow: extra.contextWindow ?? 128_000,
  reasoningLevels: extra.reasoningLevels ?? [],
  reasoningEffort:
    "reasoningEffort" in extra
      ? extra.reasoningEffort
      : n === 1
        ? "medium"
        : null,
  reasoningSummary: null,
  maxOutputTokens: null,
  hostedWebSearch: null,
  providerId: extra.providerId ?? (n === 2 ? "p2" : "p1"),
  provider: {
    id: extra.providerId ?? (n === 2 ? "p2" : "p1"),
    name: n === 2 ? "GLM" : "Prov",
  },
});

const presetModel = (
  upstreamId: string,
  name: string,
  extra: Partial<{
    contextWindow: number;
    reasoningLevels: string[];
    reasoningEffort: string | null;
    image: boolean;
    recommended: boolean;
    installed: boolean;
  }> = {},
) => ({
  upstreamId,
  slug: upstreamId,
  name,
  contextWindow: extra.contextWindow ?? 1_000_000,
  reasoningLevels: extra.reasoningLevels ?? ["low", "high", "max"],
  reasoningEffort: "reasoningEffort" in extra ? extra.reasoningEffort : "high",
  image: extra.image ?? false,
  recommended: extra.recommended ?? true,
  installed: extra.installed ?? false,
});

/** the preset catalogue as list_presets answers it: DeepSeek installed as p1 (flash there, pro not), GLM and OpenAI not */
export const presets = () => [
  {
    slug: "deepseek",
    name: "DeepSeek",
    kind: "openai_compatible",
    baseUrl: "https://api.deepseek.com/v1",
    supportsHostedWebSearch: false,
    keyEnv: "DEEPSEEK_API_KEY",
    keyUrl: "https://platform.deepseek.com/api_keys",
    docsUrl: "https://api-docs.deepseek.com/",
    installed: true,
    providerId: "p1",
    models: [
      presetModel("deepseek-flash", "DeepSeek Flash", {
        image: true,
        installed: true,
      }),
      presetModel("deepseek-v4-pro", "DeepSeek V4 Pro"),
    ],
  },
  {
    slug: "glm",
    name: "GLM",
    kind: "openai_compatible",
    baseUrl: "https://open.bigmodel.cn/api/v1",
    supportsHostedWebSearch: false,
    keyEnv: "GLM_API_KEY",
    keyUrl: "https://bigmodel.cn/",
    docsUrl: "https://docs.bigmodel.cn/",
    installed: false,
    providerId: null,
    models: [
      presetModel("glm-5.3", "GLM 5.3", { reasoningEffort: "max" }),
      presetModel("glm-5-turbo", "GLM 5 Turbo", {
        contextWindow: 200_000,
        reasoningLevels: [],
        reasoningEffort: null,
      }),
    ],
  },
  {
    slug: "openai",
    name: "OpenAI",
    kind: "openai",
    baseUrl: "https://api.openai.com/v1",
    supportsHostedWebSearch: true,
    keyEnv: "OPENAI_API_KEY",
    keyUrl: "https://platform.openai.com/api-keys",
    docsUrl: "https://developers.openai.com/codex",
    installed: false,
    providerId: null,
    models: [
      presetModel("gpt-5.6-sol", "GPT-5.6 Sol", {
        contextWindow: 272_000,
        reasoningLevels: ["low", "medium", "high", "xhigh", "max", "ultra"],
        reasoningEffort: "low",
        image: true,
      }),
      presetModel("gpt-5.5", "GPT-5.5", {
        contextWindow: 272_000,
        reasoningLevels: ["low", "medium", "high", "xhigh"],
        reasoningEffort: "medium",
        image: true,
        recommended: false,
      }),
    ],
  },
];

export const provider = (n: number, extra: Record<string, unknown> = {}) => ({
  id: `p${n}`,
  name: n === 2 ? "GLM" : "Prov",
  slug: n === 2 ? "glm" : `prov-${n}`,
  baseUrl:
    n === 2
      ? "https://open.bigmodel.cn/api/paas/v4"
      : "https://api.deepseek.com/v1",
  kind: "openai_compatible",
  hasApiKey: n === 1,
  supportsHostedWebSearch: false,
  requestTimeoutMs: 600000,
  maxConcurrentRequests: null,
  lastCheckedAt: null,
  lastError: n === 2 ? "401 Authentication Fails" : null,
  lastErrorAt: null,
  ...extra,
});

/**
 * A channel double that remembers what was joined and lets a test deliver
 * the join reply (`channel.reply("ok", snapshot)`) and deliver server pushes
 * (`channel.deliver("event", event)`) — for both the project and thread
 * topics; the shared maps hold the most recent join, `replyTo` / `deliverTo`
 * address one topic when several threads are open (a thread and its
 * sub-agents). Client pushes (`push`) are recorded; `answer(status, payload)`
 * resolves the last one.
 */
type TopicState = {
  handlers: Record<string, (payload: unknown) => void>;
  replies: Record<string, (payload: unknown) => void>;
};

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
    reconnectSocket: () => {},
    getSocket: () => ({
      channel: (topic: string) => {
        channel.topics.push(topic);
        return topicChannel(topic);
      },
    }),
  };
}
