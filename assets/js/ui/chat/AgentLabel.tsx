// The name over another agent's message. A team member is its name; a
// session addressed through the directory (`~052ca4`, `<slug>:<handle>`)
// reads as nothing to the person, so the directory's title stands in front
// of it and the label links to that session's page.
import { Link, useOutletContext } from "react-router";
import { sessionTitle, useSessions } from "@/core/projects";
import type { ProjectContext } from "@/ui/frame/ProjectWindow";
import { useChat } from "./ChatProvider";

export function AgentLabel({ from }: { from: string }) {
  const { projectId } = useChat();
  const { slug } = useOutletContext<ProjectContext>();
  const addressed = from.startsWith("~") || from.includes(":");
  const sessions = useSessions(addressed ? projectId : undefined);
  const session = addressed ? sessions.data?.find((s) => s.address === from) : undefined;
  if (!session) return <span className="font-mono">{from}</span>;
  const title = sessionTitle(session, from);
  return (
    <Link to={`/p/${session.projectSlug || slug}/t/${session.threadId}`} className="hover:text-foreground flex min-w-0 items-center gap-1.5 hover:underline">
      <span className="truncate">{title}</span>
      <span className="font-mono opacity-70">{from}</span>
    </Link>
  );
}
