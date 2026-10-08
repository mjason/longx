import { useTranslation } from "react-i18next";
import { useCommandGuardStatus, type CommandGuardStatus as Status } from "@/core/agent";
import { t } from "@/ui/strings";

// Settings-only copy stays with this lazy settings module, not the chat entry.
const copy = {
  "zh-CN": {
    cgroupStatusTitle: "任务保护：检测与实际状态",
    cgroupChecking: "读取任务保护状态…",
    cgroupSavedMode: "已保存模式",
    cgroupEligible: "具备启动保护的条件",
    cgroupUnavailable: "当前不可用",
    cgroupUnsupported: "当前平台不支持 Linux cgroup",
    cgroupOffStatus: "已关闭；未执行检测",
    cgroupUnknown: "未验证",
    cgroupStatusHint: "检测只读取系统状态，不创建 cgroup 或修改服务。以下任务报告来自全机真实任务，不限当前项目；结束报告最多保留一分钟，不表示当前仍在运行。原有进程组清理和机器内存下限保护不受此开关影响。",
    cgroupActiveTasks: (n: number) => `当前已确认启用保护的任务：${n}`,
    cgroupCleanupTasks: (n: number) => `尚未确认清理完成的任务：${n}；不要重启该工作负载`,
    cgroupLastTask: "最近收到的任务启动报告",
    cgroupTaskActive: "启动时已启用",
    cgroupTaskUnavailable: "启动时已降级",
    cgroupNoReport: "尚无任务保护报告",
    cgroupOomKills: (n: number) => `该任务 oom_kill 增量：${n}`,
    protecting: "有任务正在受 cgroup 保护",
    protectingHint: "真实任务启动报告已确认。下方数量只统计仍在运行的受保护任务。",
    ready: "环境检测通过，等待任务验证",
    readyHint: "系统具备启动保护的前置条件；只有真实任务成功启用后，才算保护已生效。",
    idle: "当前没有正在受保护的任务",
    idleHint: "最近的启动报告曾确认启用保护，但它不代表任务现在仍在运行。",
    offHint: "后续启动的任务不启用 cgroup；已运行任务的状态单独统计。",
    offTitle: "新任务的 cgroup 保护已关闭",
    unavailableTitle: "新任务无法启用 cgroup 保护",
    unavailableHint: "自动模式会继续执行，但不启用 cgroup。可展开技术详情查看原因。",
    requiredHint: "必须启用模式下，无法启用保护的新任务会拒绝启动。",
    cleanup: "任务清理需要关注",
    cleanupHint: "有任务的清理尚未确认完成。请先检查清理错误，不要重启该工作负载。",
    environment: "环境检查",
    tasks: "运行中的保护",
    recent: "最近一次启动",
    preflight: "只读检测，不启动任务，也不修改系统。",
    reportsHint: "任务报告来自全机，不限当前项目；最近报告不代表任务仍在运行。",
    details: "技术详情",
    environmentPath: "检测到的 cgroup 目录",
    taskPath: "最近任务的 cgroup 目录",
    rawReason: "检测原始原因",
    taskReason: "任务启动原因",
    checkedAt: "检测时间",
    observedAt: "最近报告时间",
    cleanupError: "清理错误",
    oom: (n: number) => `最近任务报告了 ${n} 次 OOM 终止（内存不足）。`,
  },
  en: {
    cgroupStatusTitle: "Task protection: detection and actual state",
    cgroupChecking: "Reading task protection status…",
    cgroupSavedMode: "Saved mode",
    cgroupEligible: "Prerequisites detected; task startup must still confirm protection",
    cgroupUnavailable: "Currently unavailable",
    cgroupUnsupported: "This platform does not support Linux cgroups",
    cgroupOffStatus: "Off; detection was not run",
    cgroupUnknown: "Not verified",
    cgroupStatusHint: "Detection only reads system state; it does not create cgroups or change services. Actual task reports below are machine-wide, not project-specific. Finished reports are retained for up to one minute and do not mean the task is still running. Existing process-group cleanup and the machine-wide memory guard remain enabled.",
    cgroupActiveTasks: (n: number) => `Tasks with confirmed active protection: ${n}`,
    cgroupCleanupTasks: (n: number) => `Tasks with unverified cleanup: ${n}; do not restart the workload`,
    cgroupLastTask: "Latest received task-start report",
    cgroupTaskActive: "Protection was active at startup",
    cgroupTaskUnavailable: "Fallback was used at startup",
    cgroupNoReport: "No task protection report yet",
    cgroupOomKills: (n: number) => `Task oom_kill increment: ${n}`,
    protecting: "Tasks are running with cgroup protection",
    protectingHint: "Confirmed by actual task-start reports. Only running protected tasks are counted below.",
    ready: "Environment checks passed; awaiting task verification",
    readyHint: "Prerequisites are present. Protection is only confirmed when a real task successfully enables it.",
    idle: "No protected tasks are currently running",
    idleHint: "The latest start report confirmed protection, but does not mean that task is still running.",
    offHint: "New tasks will not enable cgroups. Already-running tasks are counted separately.",
    offTitle: "Cgroup protection is off for new tasks",
    unavailableTitle: "Cgroup protection is unavailable for new tasks",
    unavailableHint: "Auto mode continues without cgroup protection. See technical details for the reason.",
    requiredHint: "Required mode refuses to start new tasks if protection cannot be enabled.",
    cleanup: "Task cleanup needs attention",
    cleanupHint: "Cleanup has not been confirmed for a task. Check the cleanup error before restarting the workload.",
    environment: "Environment check",
    tasks: "Running protection",
    recent: "Latest task start",
    preflight: "Read-only check; no tasks are started and no system changes are made.",
    reportsHint: "Task reports are machine-wide, not project-specific. A recent report does not mean a task is still running.",
    details: "Technical details",
    environmentPath: "Detected cgroup directory",
    taskPath: "Latest task cgroup directory",
    rawReason: "Raw detection reason",
    taskReason: "Task-start reason",
    checkedAt: "Checked at",
    observedAt: "Latest report at",
    cleanupError: "Cleanup error",
    oom: (n: number) => `The latest task reported ${n} OOM kills (out of memory).`,
  },
};

export function CommandGuardStatus({ projectId }: { projectId?: string }) {
  const { i18n } = useTranslation();
  const s = copy[i18n.resolvedLanguage === "en" ? "en" : "zh-CN"];
  const status = useCommandGuardStatus(projectId);
  if (status.isPending) return <p className="text-muted-foreground text-xs">{s.cgroupChecking}</p>;
  if (status.isError) return <p className="text-destructive text-xs">{status.error.message}</p>;
  return <CommandGuardStatusView data={status.data} />;
}

export function CommandGuardStatusView({ data }: { data: Status }) {
  const { i18n } = useTranslation();
  const s = copy[i18n.resolvedLanguage === "en" ? "en" : "zh-CN"];
  const capability = {
    off: s.cgroupOffStatus,
    unsupported: s.cgroupUnsupported,
    eligible: s.cgroupEligible,
    unavailable: s.cgroupUnavailable,
  }[data.capability] ?? s.cgroupUnknown;
  const mode = { auto: t.agentKernel.cgroupAuto, off: t.agentKernel.cgroupOff, required: t.agentKernel.cgroupRequired }[data.mode];
  const cleanup = data.cleanupPendingTasks > 0 || !!data.lastCleanupError;
  const unavailable = data.capability === "unavailable" || data.capability === "unsupported";
  const title = cleanup ? s.cleanup : data.activeTasks > 0 ? s.protecting :
    data.capability === "off" ? s.offTitle : unavailable ? s.unavailableTitle :
    data.lastTaskStatus === "active" ? s.idle : s.ready;
  const hint = cleanup ? s.cleanupHint : data.activeTasks > 0 ? s.protectingHint :
    data.capability === "off" ? s.offHint : unavailable ?
      (data.mode === "required" ? s.requiredHint : s.unavailableHint) :
    data.lastTaskStatus === "active" ? s.idleHint : s.readyHint;
  const taskStatus = data.lastTaskStatus === "active" ? s.cgroupTaskActive :
    data.lastTaskStatus === "unavailable" ? s.cgroupTaskUnavailable : data.lastTaskStatus ?? s.cgroupNoReport;
  const technical = [
    [s.rawReason, data.reason], [s.environmentPath, data.path],
    [s.taskReason, data.lastTaskReason], [s.taskPath, data.lastTaskPath],
    [s.checkedAt, data.checkedAt],
    [s.observedAt, data.lastObservedAt],
  ];
  return (
    <section className="min-w-0 space-y-4 rounded-lg border p-4 text-xs" data-testid="command-guard-status">
      <header className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-sm font-semibold">{s.cgroupStatusTitle}</h3>
        <p className="text-muted-foreground">{s.cgroupSavedMode}: {mode} · {data.platform}</p>
      </header>
      <div className={`space-y-1 rounded-md border-l-2 px-3 py-2 ${cleanup || unavailable && data.activeTasks === 0 ? "border-warning bg-warning/5" : data.activeTasks > 0 ? "border-emerald-500 bg-emerald-500/5" : "border-primary bg-primary/5"}`}>
        <p className="text-sm font-medium" data-testid="guard-conclusion">{title}</p>
        <p className="text-muted-foreground leading-relaxed">{hint}</p>
      </div>
      <div className="grid min-w-0 gap-3 sm:grid-cols-3">
        <div className="space-y-2 rounded-md bg-muted/30 p-3">
          <p className="text-muted-foreground">{s.environment}</p>
          <p className="font-medium">{capability}</p>
          <p className="text-muted-foreground leading-relaxed">{s.preflight}</p>
        </div>
        <div className="space-y-2 rounded-md bg-muted/30 p-3">
          <p className="text-muted-foreground">{s.tasks}</p>
          <p className="font-medium">{s.cgroupActiveTasks(data.activeTasks)}</p>
        </div>
        <div className="space-y-2 rounded-md bg-muted/30 p-3">
          <p className="text-muted-foreground">{s.recent}</p>
          <p className="font-medium">{taskStatus}</p>
          <p className="text-muted-foreground leading-relaxed">{s.reportsHint}</p>
        </div>
      </div>
      {cleanup ? <div role="alert" className="space-y-1 rounded-md border border-destructive/20 bg-destructive/5 p-3 text-destructive">
        <p>{s.cgroupCleanupTasks(data.cleanupPendingTasks)}</p>
        {data.lastCleanupError ? <p className="break-all whitespace-pre-wrap">{data.lastCleanupError}</p> : null}
      </div> : null}
      {data.lastOomKill !== null && data.lastOomKill > 0 ? <p className="text-warning">{s.oom(data.lastOomKill)}</p> : null}
      <details className="border-t pt-3">
        <summary className="text-muted-foreground cursor-pointer">{s.details}</summary>
        <dl className="mt-3 space-y-3">
          {technical.map(([label, value]) => value ? <div key={label}>
            <dt className="text-muted-foreground">{label}</dt>
            <dd className="mt-1 break-all font-mono whitespace-pre-wrap">{value}</dd>
          </div> : null)}
        </dl>
        {data.lastOomKill !== null ? <p className="mt-3">{s.cgroupOomKills(data.lastOomKill)}</p> : null}
        <p className="text-muted-foreground mt-3 leading-relaxed">{s.cgroupStatusHint}</p>
      </details>
    </section>
  );
}
