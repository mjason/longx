import { useTranslation } from "react-i18next";
import { useContext, useEffect, useRef, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useOutletContext, useParams } from "react-router";
import { Bot, Terminal, Square } from "lucide-react";
import { toast } from "sonner";
import { setThreadJobPurpose, stopThreadJob, threadJobOutput } from "@/core/api";
import { queryKeys, unwrap, useProjectJobs, type ProjectJob } from "@/core/projects";
import type { ProjectContext } from "@/ui/frame/ProjectWindow";
import { relativeTime } from "@/core/format";
import { runningTurnId } from "@/core/chat/thread";
import { useChat } from "./ChatProvider";
import { agentSummaries } from "./AgentsPanel";
import { SubagentContext } from "./toolkit";
import { Button } from "@/ui/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/ui/components/ui/popover";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/ui/components/ui/alert-dialog";
import { t } from "@/ui/strings";
import { useIntent } from "@/core/keys/intents";
import { useJobHints } from "./job-copy";

function useJobs() {
  const ctx = useOutletContext<ProjectContext>();
  const { threadId } = useParams();
  const { view } = useChat();
  const client = useQueryClient();
  const running = runningTurnId(view) !== null;
  const query = useProjectJobs(ctx.id);
  useEffect(() => {
    void client.invalidateQueries({ queryKey: queryKeys.projectJobs(ctx.id) });
  }, [client, ctx.id, running]);
  return (query.data ?? []).filter(job => job.rootThreadId === threadId || job.threadId === threadId);
}

function JobRow({ job }: { job: ProjectJob }) {
  useTranslation();
  const hints = useJobHints();
  const ctx = useOutletContext<ProjectContext>();
  const client = useQueryClient();
  const [logs, setLogs] = useState(false);
  const [confirm, setConfirm] = useState<"stop" | "purpose" | null>(null);
  const sending = useRef(false);
  const input = { threadId: job.threadId, name: job.name, run: job.run ?? "" };
  const output = useQuery({
    queryKey: ["job-output", job.threadId, job.name, job.run],
    queryFn: async () => unwrap(await threadJobOutput({ input })),
    enabled: logs && !!job.run,
    refetchInterval: logs && job.status === "running" ? 5_000 : false,
  });
  const mutation = useMutation({
    mutationFn: async (operation: "stop" | "purpose") => {
      if (sending.current) return;
      sending.current = true;
      try {
        return unwrap(await (operation === "stop"
          ? stopThreadJob({ input })
          : setThreadJobPurpose({ input: { ...input, purpose: job.purpose === "wait" ? "background" : "wait" } })));
      } finally {
        sending.current = false;
      }
    },
    onSuccess: () => {
      void client.invalidateQueries({ queryKey: queryKeys.projectJobs(ctx.id) });
      void client.invalidateQueries({ queryKey: queryKeys.running });
    },
    onError: (error) => toast.error(error.message),
  });
  const state = job.activity ?? (job.status === "running" ? "waiting" : "complete");
  return <div className="min-w-0 border-b p-3 last:border-0" data-testid="thread-job-row">
    <div className="flex flex-wrap items-center justify-between gap-2 text-xs">
      <code className="min-w-0 break-all font-medium">{job.name}</code>
      <span className={state === "incomplete" ? "text-destructive" : state === "complete" ? "text-muted-foreground" : "text-warning"}>
        {job.purpose === "background" && job.status === "running" ? t.jobWork.running : t.jobWork.states[state]}
      </span>
    </div>
    <code className="text-muted-foreground mt-1 block truncate text-[11px]" title={job.cmd}>{job.cmd}</code>
    <div className="mt-2 flex flex-wrap items-center gap-3 text-[11px]">
      <button type="button" className="text-muted-foreground hover:underline" disabled={!job.run || mutation.isPending} onClick={() => setConfirm("purpose")} aria-label={`${t.jobWork.purpose} ${job.name}`}>
        {job.purpose === "wait" ? t.jobWork.waitPurpose : t.jobWork.backgroundPurpose}
      </button>
      {job.startedAt ? <span className="text-muted-foreground">{relativeTime(job.startedAt)}</span> : null}
      <button type="button" className="text-primary hover:underline" disabled={!job.run} onClick={() => setLogs(!logs)}>{t.jobWork.logs}</button>
      {job.status === "running" ? <button type="button" className="text-destructive hover:underline" disabled={!job.run || mutation.isPending} onClick={() => setConfirm("stop")}>{t.jobWork.stop}</button> : null}
    </div>
    {job.reviewNote ? <p className="text-muted-foreground mt-2 break-words text-xs">{job.reviewNote}</p> : null}
    {logs ? <div className="mt-2" role="region" aria-label={`${t.jobWork.logs} ${job.name}`}>
      {output.error ? <p role="alert" className="text-destructive text-xs">{output.error.message}</p>
        : <pre className="bg-muted max-h-48 overflow-auto rounded p-2 text-[11px] whitespace-pre-wrap break-all">{output.data?.text ?? "…"}</pre>}
    </div> : null}
    <AlertDialog open={confirm !== null} onOpenChange={open => { if (!open) setConfirm(null); }}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{confirm === "stop" ? t.jobWork.stopTitle : t.jobWork.purposeTitle}</AlertDialogTitle>
          <AlertDialogDescription>{confirm === "stop" ? hints.stopHint : job.purpose === "wait" ? hints.purposeHint : hints.waitHint}</AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>{t.cancel}</AlertDialogCancel>
          <AlertDialogAction disabled={mutation.isPending} onClick={() => { if (confirm) mutation.mutate(confirm); }}>
            {confirm === "stop" ? t.jobWork.stopConfirm : t.jobWork.confirm}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  </div>;
}

export function ThreadResources() {
  useTranslation();
  const hints = useJobHints();
  const jobs = useJobs();
  const chat = useChat();
  const agents = agentSummaries(chat.view, chat.subviews);
  const subagents = useContext(SubagentContext);
  const [stopping, setStopping] = useState<string | null>(null);
  const [agentsOpen, setAgentsOpen] = useState(false);
  useIntent("agents.panel", () => setAgentsOpen(!agentsOpen));
  const background = jobs.filter(job => job.purpose !== "wait" && job.status === "running");
  if (!agents.length && !background.length) return null;
  return <div className="flex shrink-0 justify-end gap-2 px-3 py-2" data-testid="thread-resources">
    {agents.length ? <Popover open={agentsOpen} onOpenChange={setAgentsOpen}><PopoverTrigger asChild>
      <Button size="sm" variant="outline" className="h-7 gap-1.5 text-xs"><Bot className="size-3.5" />{t.jobWork.agentsCount(agents.length)}</Button>
    </PopoverTrigger><PopoverContent align="end" className="w-80 max-w-[calc(100vw-2rem)] p-3" data-testid="thread-agents-popover">
      <p className="mb-3 text-sm font-medium">{t.agentsPanel.title}</p>
      {agents.every(agent => agent.state === "done") ? <p className="text-muted-foreground mb-2 text-xs">{t.agentsPanel.recentlyDone}</p> : null}
      <ul className="flex flex-col gap-3">{agents.map(agent => <li key={agent.threadId} className="flex items-center gap-2 text-xs">
        <button type="button" className="flex min-w-0 flex-1 flex-col items-start text-start hover:underline" onClick={() => subagents?.open(agent.threadId, agent.name)}>
          <code>{agent.name}</code><span className="text-muted-foreground line-clamp-2">{agent.label}</span>
        </button>
        {agent.state === "working" ? <Button size="icon" variant="ghost" className="size-6" aria-label={`${t.stopSubagent} ${agent.name}`} disabled={stopping !== null} onClick={async () => {
          setStopping(agent.threadId);
          try { await subagents?.stop(agent.threadId); } catch (error) { toast.error(error instanceof Error ? error.message : String(error)); } finally { setStopping(null); }
        }}><Square className="size-3" /></Button> : null}
      </li>)}</ul>
    </PopoverContent></Popover> : null}
    {background.length ? <Popover><PopoverTrigger asChild>
      <Button size="sm" variant="outline" className="h-7 gap-1.5 text-xs"><Terminal className="size-3.5" />{t.jobWork.backgroundCount(background.length)}</Button>
    </PopoverTrigger><PopoverContent align="end" className="max-h-[70vh] w-96 max-w-[calc(100vw-2rem)] overflow-y-auto p-0" data-testid="thread-background-popover">
      <div className="border-b p-3"><p className="text-sm font-medium">{t.jobWork.background}</p><p className="text-muted-foreground mt-1 text-xs">{hints.backgroundHint}</p></div>
      {background.map(job => <JobRow key={`${job.threadId}:${job.run ?? job.name}`} job={job} />)}
    </PopoverContent></Popover> : null}
  </div>;
}

export function JobWorkStatus() {
  useTranslation();
  const hints = useJobHints();
  const jobs = useJobs();
  const { view, sendText, disabledReason } = useChat();
  const [checking, setChecking] = useState(false);
  const [expanded, setExpanded] = useState(false);
  const pending = jobs.filter(job => job.purpose === "wait" && job.activity !== "complete");
  if (!pending.length) return null;
  const running = pending.filter(job => job.activity === "waiting").length;
  const processing = pending.filter(job => job.activity === "processing").length;
  const incomplete = pending.some(job => job.activity === "incomplete");
  return <section className="border-warning/30 bg-warning/5 mx-2 mb-2 rounded-lg border text-xs" data-testid="job-work-status" aria-label={t.jobWork.count(pending.length)}>
    <div className="p-3">
      <p role="status" className={incomplete ? "text-destructive font-medium" : "text-warning font-medium"}>
        {incomplete ? t.jobWork.states.incomplete : hints.title(running, pending.length - running - processing, processing)}
      </p>
      <p className="text-muted-foreground mt-1 leading-relaxed">{view.waiting.paused ? hints.pausedHint : incomplete ? hints.incompleteHint : !running && !processing ? hints.pendingHint : pending.some(job => job.notify === false) ? hints.manualHint : hints.hint}</p>
      <button type="button" className="text-primary mt-2 hover:underline" aria-expanded={expanded} onClick={() => setExpanded(!expanded)}>{expanded ? t.jobWork.hide : t.jobWork.show}</button>
      {!running && runningTurnId(view) === null ? <button type="button" className="text-primary ms-4 mt-2 hover:underline disabled:opacity-50" disabled={checking || !!disabledReason} onClick={async () => {
        setChecking(true);
        try { await sendText(hints.checkMessage); } catch (error) { toast.error(error instanceof Error ? error.message : String(error)); } finally { setChecking(false); }
      }}>{t.jobWork.check}</button> : null}
    </div>
    {expanded ? <div className="max-h-64 overflow-y-auto border-t">{pending.map(job => <JobRow key={`${job.threadId}:${job.run ?? job.name}`} job={job} />)}</div> : null}
  </section>;
}
