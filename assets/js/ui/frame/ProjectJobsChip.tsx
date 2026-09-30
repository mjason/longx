import { useTranslation } from "react-i18next";
import { CircleDot } from "lucide-react";
import { Link } from "react-router";
import { relativeTime } from "@/core/format";
import { useProjectJobs, type ProjectJob } from "@/core/projects";
import { Popover, PopoverContent, PopoverTrigger } from "@/ui/components/ui/popover";
import { t } from "@/ui/strings";

function JobRow({ job, slug }: { job: ProjectJob; slug: string }) {
    useTranslation();
  return (
    <Link
      to={`/p/${slug}/t/${job.threadId}`}
      className="hover:bg-accent/50 flex items-start gap-2.5 border-b px-3 py-3 last:border-0"
      aria-label={`${job.name} · ${t.projectJobs.session(job.threadTitle, job.threadId)}`}
    >
      <CircleDot className="text-primary mt-0.5 size-4 shrink-0 animate-pulse" aria-hidden="true" />
      <span className="min-w-0 flex-1">
        <span className="flex items-center justify-between gap-2">
          <span className="truncate text-sm font-medium">{job.threadTitle || job.name}</span>
          <span className="text-primary shrink-0 text-xs">{t.projectJobs.running}</span>
        </span>
        <span className="text-muted-foreground mt-1 block truncate text-xs">{job.name} · {t.projectJobs.session(job.threadTitle, job.threadId)}</span>
        <code className="text-muted-foreground mt-1 block truncate text-[11px]" title={job.cmd}>{job.cmd}</code>
        <span className="text-muted-foreground mt-1 block text-[11px]">{relativeTime(job.startedAt)}</span>
      </span>
    </Link>
  );
}

/** The project's Longx-managed shell jobs, kept visible from every conversation. */
export function ProjectJobsChip({ projectId, slug, className = "" }: { projectId: string; slug: string; className?: string }) {
    useTranslation();
  const query = useProjectJobs(projectId);
  const running = (query.data ?? []).filter((job) => job.status === "running");
  if (running.length === 0) return null;

  return (
    <Popover>
      <PopoverTrigger asChild>
        <button
          type="button"
          className={`${className} text-primary cursor-pointer hover:underline`}
          title={t.projectJobs.title}
          data-testid="project-jobs-chip"
        >
          <span className="bg-primary size-2 shrink-0 animate-pulse rounded-full" aria-hidden="true" />
          {t.projectJobs.chip(running.length)}
        </button>
      </PopoverTrigger>
      <PopoverContent side="top" align="start" className="w-[min(28rem,calc(100vw-1.5rem))] overflow-hidden p-0" data-testid="project-jobs-popover">
        <div className="flex items-center justify-between border-b px-3 py-2.5">
          <span className="text-sm font-medium">{t.projectJobs.title}</span>
          <span className="text-muted-foreground text-xs">{t.runningJobs(running.length)}</span>
        </div>
        <section aria-label={t.projectJobs.running} className="max-h-64 overflow-y-auto">
          {running.map((job) => <JobRow key={`${job.threadId}:${job.name}`} job={job} slug={slug} />)}
        </section>
      </PopoverContent>
    </Popover>
  );
}
