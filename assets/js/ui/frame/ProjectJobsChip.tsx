import { CheckCircle2, CircleDot, CircleStop } from "lucide-react";
import { Link } from "react-router";
import { relativeTime } from "@/core/format";
import { useProjectJobs, type ProjectJob } from "@/core/projects";
import { Popover, PopoverContent, PopoverTrigger } from "@/ui/components/ui/popover";
import { t } from "@/ui/strings";

function outcome(job: ProjectJob) {
  if (job.status === "running") return t.projectJobs.running;
  if (job.status === "exited" && job.exitCode === 0) return t.projectJobs.completed;
  if (job.status === "stopped" || job.status === "killed") return t.projectJobs.stopped;
  return job.exitCode == null ? t.projectJobs.failed : t.projectJobs.exit(job.exitCode);
}

function JobRow({ job, slug }: { job: ProjectJob; slug: string }) {
  const running = job.status === "running";
  const success = job.status === "exited" && job.exitCode === 0;
  const Icon = running ? CircleDot : success ? CheckCircle2 : CircleStop;
  const tone = running ? "text-primary" : success ? "text-muted-foreground" : "text-destructive";
  const when = running ? job.startedAt : job.finishedAt;

  return (
    <Link
      to={`/p/${slug}/t/${job.threadId}`}
      className="hover:bg-accent/50 flex items-start gap-2.5 border-b px-3 py-3 last:border-0"
      aria-label={`${job.name} · ${t.projectJobs.session(job.threadTitle, job.threadId)}`}
    >
      <Icon className={`mt-0.5 size-4 shrink-0 ${tone} ${running ? "animate-pulse" : ""}`} aria-hidden="true" />
      <span className="min-w-0 flex-1">
        <span className="flex items-center justify-between gap-2">
          <span className="truncate text-sm font-medium">{job.threadTitle || job.name}</span>
          <span className={`shrink-0 text-xs ${tone}`}>{outcome(job)}</span>
        </span>
        <span className="text-muted-foreground mt-1 block truncate text-xs">{job.name} · {t.projectJobs.session(job.threadTitle, job.threadId)}</span>
        <code className="text-muted-foreground mt-1 block truncate text-[11px]" title={job.cmd}>{job.cmd}</code>
        <span className="text-muted-foreground mt-1 block text-[11px]">{relativeTime(when)}</span>
      </span>
    </Link>
  );
}

/** The project's Longx-managed shell jobs, kept visible from every conversation. */
export function ProjectJobsChip({ projectId, slug, className = "" }: { projectId: string; slug: string; className?: string }) {
  const query = useProjectJobs(projectId);
  const jobs = query.data ?? [];
  if (jobs.length === 0) return null;

  const running = jobs.filter((job) => job.status === "running");
  const finished = jobs.filter((job) => job.status !== "running");

  return (
    <Popover>
      <PopoverTrigger asChild>
        <button
          type="button"
          className={`${className} text-primary cursor-pointer hover:underline`}
          title={t.projectJobs.title}
          data-testid="project-jobs-chip"
        >
          {running.length > 0 ? (
            <span className="bg-primary size-2 shrink-0 animate-pulse rounded-full" aria-hidden="true" />
          ) : (
            <CheckCircle2 className="size-3" aria-hidden="true" />
          )}
          {t.projectJobs.chip(jobs.length)}
        </button>
      </PopoverTrigger>
      <PopoverContent side="top" align="start" className="w-[min(28rem,calc(100vw-1.5rem))] overflow-hidden p-0" data-testid="project-jobs-popover">
        <div className="flex items-center justify-between border-b px-3 py-2.5">
          <span className="text-sm font-medium">{t.projectJobs.title}</span>
          <span className="text-muted-foreground text-xs">{running.length} 运行中 · {finished.length} 最近完成</span>
        </div>
        {running.length > 0 ? (
          <section aria-label={t.projectJobs.running} className="max-h-64 overflow-y-auto">
            {running.map((job) => <JobRow key={`${job.threadId}:${job.name}`} job={job} slug={slug} />)}
          </section>
        ) : null}
        {finished.length > 0 ? (
          <section aria-label={t.projectJobs.recent} className="max-h-64 overflow-y-auto border-t">
            {finished.map((job) => <JobRow key={`${job.threadId}:${job.name}`} job={job} slug={slug} />)}
          </section>
        ) : null}
      </PopoverContent>
    </Popover>
  );
}
