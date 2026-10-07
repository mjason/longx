import { useTranslation } from "react-i18next";
import { useCommandGuardStatus, type CommandGuardStatus as Status } from "@/core/agent";
import { t } from "@/ui/strings";

// Settings-only copy stays with this lazy settings module, not the chat entry.
const copy = {
  "zh-CN": {
    cgroupStatusTitle: "任务保护：检测与实际状态",
    cgroupChecking: "读取任务保护状态…",
    cgroupSavedMode: "已保存模式",
    cgroupEligible: "前置检测满足条件；待真实任务启动确认",
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
  return (
    <div className="space-y-2 rounded-md border p-3 text-xs" data-testid="command-guard-status">
      <p className="text-sm font-medium">{s.cgroupStatusTitle}</p>
      <p>{s.cgroupSavedMode}: {mode} · {data.platform}</p>
      <p>{capability}</p>
      {data.reason ? <p className="text-muted-foreground whitespace-pre-wrap break-all">{data.reason}</p> : null}
      {data.path ? <p className="font-mono break-all">{data.path}</p> : null}
      <p>{s.cgroupActiveTasks(data.activeTasks)}</p>
      {data.cleanupPendingTasks > 0 ? <p role="alert" className="text-destructive">{s.cgroupCleanupTasks(data.cleanupPendingTasks)}</p> : null}
      {data.lastTaskStatus ? (
        <div className="space-y-1">
          <p>{s.cgroupLastTask}: <span>{data.lastTaskStatus === "active" ? s.cgroupTaskActive : data.lastTaskStatus === "unavailable" ? s.cgroupTaskUnavailable : data.lastTaskStatus}</span></p>
          {data.lastTaskReason ? <p className="whitespace-pre-wrap break-all">{data.lastTaskReason}</p> : null}
          {data.lastTaskPath ? <p className="font-mono break-all">{data.lastTaskPath}</p> : null}
        </div>
      ) : <p>{s.cgroupNoReport}</p>}
      {data.lastCleanupError ? <p className="text-destructive whitespace-pre-wrap break-all">{data.lastCleanupError}</p> : null}
      {data.lastOomKill !== null ? <p>{s.cgroupOomKills(data.lastOomKill)}</p> : null}
      <p className="text-muted-foreground">{s.cgroupStatusHint}</p>
    </div>
  );
}
