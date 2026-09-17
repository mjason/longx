import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { useNavigate, useOutletContext } from "react-router";
import { toast } from "sonner";
import { archiveProject, clearCodexHistory, clearCodexMemories, deleteProject, resetCodexHome, updateProject, type UpdateProjectInput } from "@/ash_rpc";
import { queryKeys, unwrap, useAgentDefinition, useModels, useProject, useSandboxStatus, useSkills } from "@/core/projects";
import { ChevronRight } from "lucide-react";
import { Button } from "@/ui/components/ui/button";
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/ui/components/ui/collapsible";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/ui/components/ui/dialog";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { RadioGroup, RadioGroupItem } from "@/ui/components/ui/radio-group";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/ui/components/ui/select";
import { Badge } from "@/ui/components/ui/badge";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { Switch } from "@/ui/components/ui/switch";
import { Textarea } from "@/ui/components/ui/textarea";
import type { ProjectContext } from "@/ui/frame/ProjectWindow";
import { t } from "@/ui/strings";

type Form = Required<Pick<UpdateProjectInput, "name" | "sandbox" | "approvalPolicy" | "networkAccess" | "webSearch" | "multiAgent" | "autoReview" | "globalMemory" | "dirtyStart" | "engine" | "trustLocalAgent">> & {
  description: string;
  memoryLimitMb: string;
  modelId: string;
  writableRoots: string;
  passthroughPaths: string;
};

/**
 * The project's settings: what every new thread starts with (access mode,
 * dirty-tree policy, model, memory cap), and the codex / project danger
 * zone. Thread-level overrides live in the composer rail.
 */
export function ProjectSettingsPage() {
  const ctx = useOutletContext<ProjectContext>();
  const project = useProject(ctx.slug);
  if (project.isPending) return <Skeleton className="m-4 h-40" data-testid="chat-area" />;
  if (project.isError) return <p className="text-destructive p-4">{project.error.message}</p>;
  return <SettingsForm key={project.data.updatedAt} project={project.data} slug={ctx.slug} />;
}

type Project = NonNullable<ReturnType<typeof useProject>["data"]>;

function SettingsForm({ project, slug }: { project: Project; slug: string }) {
  const client = useQueryClient();
  const navigate = useNavigate();
  const models = useModels();
  const sandbox = useSandboxStatus();
  const [form, setForm] = useState<Form>({
    name: project.name,
    description: project.description ?? "",
    sandbox: project.sandbox,
    approvalPolicy: project.approvalPolicy,
    networkAccess: project.networkAccess,
    webSearch: project.webSearch,
    multiAgent: project.multiAgent,
    autoReview: project.autoReview,
    globalMemory: project.globalMemory,
    dirtyStart: project.dirtyStart,
    engine: project.engine,
    trustLocalAgent: project.trustLocalAgent,
    memoryLimitMb: project.memoryLimitMb ? String(project.memoryLimitMb) : "",
    modelId: "__default",
    writableRoots: project.writableRoots.join("\n"),
    passthroughPaths: project.passthroughPaths.join("\n"),
  });
  const [confirming, setConfirming] = useState<"clear" | "memories" | "reset" | "archive" | "delete" | null>(null);
  const set = <K extends keyof Form>(key: K, value: Form[K]) => setForm((f) => ({ ...f, [key]: value }));
  const linux = sandbox.data?.platform === "linux";

  const save = useMutation({
    mutationFn: async () =>
      unwrap(
        await updateProject({
          identity: project.id,
          fields: ["id"],
          input: {
            name: form.name,
            description: form.description || null,
            sandbox: form.sandbox,
            approvalPolicy: form.approvalPolicy,
            networkAccess: form.networkAccess,
            webSearch: form.webSearch,
            multiAgent: form.multiAgent,
            autoReview: form.autoReview,
            globalMemory: form.globalMemory,
            dirtyStart: form.dirtyStart,
            engine: form.engine,
            trustLocalAgent: form.trustLocalAgent,
            memoryLimitMb: form.memoryLimitMb ? Number(form.memoryLimitMb) : null,
            modelId: form.modelId === "__default" ? null : form.modelId,
            writableRoots: form.writableRoots.split("\n").map((l) => l.trim()).filter(Boolean),
            passthroughPaths: form.passthroughPaths.split("\n").map((l) => l.trim()).filter(Boolean),
          },
        }),
      ),
    onSuccess: () => {
      toast.success(t.saved);
      client.invalidateQueries({ queryKey: queryKeys.project(slug) });
      client.invalidateQueries({ queryKey: queryKeys.projects });
      client.invalidateQueries({ queryKey: ["project", project.id, "agent-definition"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const clear = useMutation({
    mutationFn: async () => unwrap(await clearCodexHistory({ input: { id: project.id } })),
    onSuccess: () => {
      toast.success(t.codexHistoryCleared);
      client.invalidateQueries({ queryKey: queryKeys.threads(project.id) });
      client.invalidateQueries({ queryKey: queryKeys.codex(project.id) });
      setConfirming(null);
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const archive = useMutation({
    mutationFn: async () => unwrap(await archiveProject({ identity: project.id, fields: ["id"] })),
    onSuccess: () => {
      client.invalidateQueries({ queryKey: queryKeys.projects });
      navigate("/");
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const codexDone = (message: string) => () => {
    toast.success(message);
    client.invalidateQueries({ queryKey: queryKeys.threads(project.id) });
    client.invalidateQueries({ queryKey: queryKeys.codex(project.id) });
    setConfirming(null);
  };
  const clearMemories = useMutation({
    mutationFn: async () => unwrap(await clearCodexMemories({ input: { id: project.id } })),
    onSuccess: codexDone(t.codexMemoriesCleared),
    onError: (e: Error) => toast.error(e.message),
  });
  const reset = useMutation({
    mutationFn: async () => unwrap(await resetCodexHome({ input: { id: project.id } })),
    onSuccess: codexDone(t.codexHomeReset),
    onError: (e: Error) => toast.error(e.message),
  });
  const remove = useMutation({
    mutationFn: async () => unwrap(await deleteProject({ identity: project.id, input: { confirm: true } })),
    onSuccess: () => {
      toast.success(t.projectDeleted);
      client.invalidateQueries({ queryKey: queryKeys.projects });
      navigate("/");
    },
    onError: (e: Error) => toast.error(e.message),
  });
  const [typedName, setTypedName] = useState("");

  // the confirm dialog: one per danger, with its words and its action
  const dangers = {
    clear: { title: t.clearCodexHistory, hint: t.clearCodexHistoryHint, confirm: t.confirmClear, run: clear },
    memories: { title: t.clearCodexMemories, hint: t.clearCodexMemoriesHint, confirm: t.confirmClear, run: clearMemories },
    reset: { title: t.resetCodexHome, hint: t.resetCodexHomeHint, confirm: t.confirmReset, run: reset },
    archive: { title: t.archiveProject, hint: t.archiveProjectHint, confirm: t.confirmArchive, run: archive },
    delete: { title: t.deleteProject, hint: t.deleteProjectHint(project.name), confirm: t.confirmDelete, run: remove },
  } as const;
  const danger = confirming ? dangers[confirming] : null;

  return (
    <div className="mx-auto flex w-full max-w-2xl flex-col gap-8 overflow-y-auto p-4" data-testid="project-settings">
      <section className="space-y-4">
        <h2 className="text-lg font-medium">{t.projectSettings}</h2>
        <div className="space-y-2">
          <Label htmlFor="ps-name">{t.name}</Label>
          <Input id="ps-name" value={form.name} onChange={(e) => set("name", e.target.value)} />
        </div>
        <div className="space-y-2">
          <Label htmlFor="ps-desc">{t.description}</Label>
          <Textarea id="ps-desc" rows={2} value={form.description} onChange={(e) => set("description", e.target.value)} />
        </div>
        <p className="text-muted-foreground font-mono text-xs">{project.rootPath}</p>
      </section>

      <section className="space-y-4">
        <h2 className="text-lg font-medium">{t.threadDefaults}</h2>
        <p className="text-muted-foreground text-sm">{t.threadDefaultsHint}</p>
        <fieldset className="space-y-2">
          <legend className="text-sm font-medium">{t.engine}</legend>
          <RadioGroup value={form.engine} onValueChange={(v) => set("engine", v as Form["engine"])}>
            {(["codex", "native"] as const).map((e) => (
              <div key={e} className="flex items-center gap-2">
                <RadioGroupItem value={e} id={`ps-engine-${e}`} />
                <Label htmlFor={`ps-engine-${e}`}>{t.engineOptions[e]}</Label>
              </div>
            ))}
          </RadioGroup>
          {form.engine === "native" ? <p className="text-destructive text-xs">{t.engineNativeHint}</p> : null}
        </fieldset>
        <fieldset className="space-y-2">
          <legend className="text-sm font-medium">{t.sandbox}</legend>
          <RadioGroup value={form.sandbox} onValueChange={(v) => set("sandbox", v as Form["sandbox"])}>
            {(["read_only", "workspace_write", "danger_full_access"] as const).map((s) => (
              <div key={s} className="flex items-center gap-2">
                <RadioGroupItem value={s} id={`ps-sandbox-${s}`} />
                <Label htmlFor={`ps-sandbox-${s}`}>{t.sandboxOptions[s]}</Label>
              </div>
            ))}
          </RadioGroup>
        </fieldset>
        <fieldset className="space-y-2">
          <legend className="text-sm font-medium">{t.approval}</legend>
          <RadioGroup value={form.approvalPolicy} onValueChange={(v) => set("approvalPolicy", v as Form["approvalPolicy"])}>
            {(["on_request", "auto_accept", "untrusted", "never"] as const).map((a) => (
              <div key={a} className="flex items-center gap-2">
                <RadioGroupItem value={a} id={`ps-approval-${a}`} />
                <Label htmlFor={`ps-approval-${a}`} className={a === "auto_accept" ? "text-destructive" : ""}>
                  {t.approvalOptions[a]}
                </Label>
              </div>
            ))}
          </RadioGroup>
        </fieldset>
        <div className="flex items-center justify-between gap-4">
          <div>
            <Label htmlFor="ps-network">{t.network}</Label>
            <p className="text-muted-foreground text-xs">{t.networkHint}</p>
          </div>
          <Switch id="ps-network" checked={form.networkAccess} onCheckedChange={(v) => set("networkAccess", v)} />
        </div>
        <Collapsible>
          <CollapsibleTrigger className="text-muted-foreground hover:text-foreground flex items-center gap-1 text-sm [&[data-state=open]>svg]:rotate-90">
            <ChevronRight className="size-4 transition-transform" /> {t.sandboxAdvanced}
          </CollapsibleTrigger>
          <CollapsibleContent className="mt-3 flex flex-col gap-4">
            <p className="text-muted-foreground text-xs">{t.sandboxAdvancedHint}</p>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="ps-writable-roots">{t.writableRoots}</Label>
              <Textarea id="ps-writable-roots" rows={2} value={form.writableRoots} onChange={(e) => set("writableRoots", e.target.value)} className="font-mono text-sm" />
              <p className="text-muted-foreground text-xs">{t.writableRootsHint}</p>
            </div>
            {linux ? (
              <div className="flex flex-col gap-1.5">
                <Label htmlFor="ps-passthrough">{t.passthrough}</Label>
                <Textarea id="ps-passthrough" rows={2} value={form.passthroughPaths} onChange={(e) => set("passthroughPaths", e.target.value)} className="font-mono text-sm" />
                <p className="text-muted-foreground text-xs">{t.passthroughHint}</p>
              </div>
            ) : null}
          </CollapsibleContent>
        </Collapsible>
        <div className="flex items-center justify-between gap-4">
          <Label htmlFor="ps-web-search">{t.webSearch}</Label>
          <Switch id="ps-web-search" checked={form.webSearch} onCheckedChange={(v) => set("webSearch", v)} />
        </div>
        <div className="flex items-center justify-between gap-4">
          <Label htmlFor="ps-multi-agent">{t.multiAgent}</Label>
          <Switch id="ps-multi-agent" checked={form.multiAgent} onCheckedChange={(v) => set("multiAgent", v)} />
        </div>
        <div className="flex items-center justify-between gap-4">
          <Label htmlFor="ps-auto-review">{t.autoReviewSwitch}</Label>
          <Switch id="ps-auto-review" checked={form.autoReview} disabled={form.approvalPolicy === "auto_accept"} onCheckedChange={(v) => set("autoReview", v)} />
        </div>
        <div className="flex items-center justify-between gap-4">
          <div>
            <Label htmlFor="ps-global-memory">{t.globalMemory}</Label>
            <p className="text-muted-foreground mt-0.5 text-xs">{t.globalMemoryHint}</p>
          </div>
          <Switch id="ps-global-memory" checked={form.globalMemory} onCheckedChange={(v) => set("globalMemory", v)} />
        </div>
        <fieldset className="space-y-2">
          <legend className="text-sm font-medium">{t.dirtyStart}</legend>
          <p className="text-muted-foreground text-xs">{t.dirtyStartHint}</p>
          <RadioGroup value={form.dirtyStart} onValueChange={(v) => set("dirtyStart", v as Form["dirtyStart"])}>
            {(["commit", "ask", "off"] as const).map((d) => (
              <div key={d} className="flex items-center gap-2">
                <RadioGroupItem value={d} id={`ps-dirty-${d}`} />
                <Label htmlFor={`ps-dirty-${d}`}>{t.dirtyStartOptions[d]}</Label>
              </div>
            ))}
          </RadioGroup>
        </fieldset>
        <div className="flex items-center gap-4">
          <Label htmlFor="ps-model" className="w-24 shrink-0">
            {t.model}
          </Label>
          <Select value={form.modelId} onValueChange={(v) => set("modelId", v)}>
            <SelectTrigger id="ps-model" className="font-mono text-xs">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="__default" className="font-mono text-xs">
                {t.globalDefaultModel}
              </SelectItem>
              {(models.data ?? []).map((m) => (
                <SelectItem key={m.id} value={m.id} className="font-mono text-xs">
                  {m.slug ?? m.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="flex items-center gap-4">
          <Label htmlFor="ps-memory" className="w-24 shrink-0">
            {t.memoryLimit}
          </Label>
          <Input id="ps-memory" type="number" min={64} placeholder={t.unlimited} value={form.memoryLimitMb} onChange={(e) => set("memoryLimitMb", e.target.value)} className="w-40" />
          <span className="text-muted-foreground text-xs">MB</span>
        </div>
        <Button onClick={() => save.mutate()} disabled={save.isPending}>
          {t.save}
        </Button>
      </section>

      {project.engine === "native" ? (
        <AgentSection projectId={project.id} trusted={form.trustLocalAgent} onTrust={(v) => set("trustLocalAgent", v)} />
      ) : (
        <SkillsSection projectId={project.id} rootPath={project.rootPath} />
      )}

      <section className="space-y-3">
        <h2 className="text-destructive text-lg font-medium">{t.dangerZone}</h2>
        <p className="text-muted-foreground text-xs">{t.dangerHint}</p>
        <div className="flex flex-wrap gap-2">
          <Button variant="outline" onClick={() => setConfirming("clear")}>
            {t.clearCodexHistory}
          </Button>
          <Button variant="outline" onClick={() => setConfirming("memories")}>
            {t.clearCodexMemories}
          </Button>
          <Button variant="outline" onClick={() => setConfirming("reset")}>
            {t.resetCodexHome}
          </Button>
          <Button variant="outline" onClick={() => setConfirming("archive")}>
            {t.archiveProject}
          </Button>
          <Button variant="outline" className="text-destructive" onClick={() => setConfirming("delete")}>
            {t.deleteProject}
          </Button>
        </div>
      </section>

      <Dialog
        open={danger !== null}
        onOpenChange={(open) => {
          if (!open) {
            setConfirming(null);
            setTypedName("");
          }
        }}
      >
        {danger ? (
          <DialogContent>
            <DialogHeader>
              <DialogTitle>{danger.title}</DialogTitle>
              <DialogDescription>{danger.hint}</DialogDescription>
            </DialogHeader>
            {confirming === "delete" ? <Input value={typedName} onChange={(e) => setTypedName(e.target.value)} placeholder={project.name} autoFocus /> : null}
            <DialogFooter className="gap-2">
              <Button variant="ghost" onClick={() => setConfirming(null)}>
                {t.cancel}
              </Button>
              <Button variant="destructive" onClick={() => danger.run.mutate()} disabled={danger.run.isPending || (confirming === "delete" && typedName.trim() !== project.name)}>
                {danger.confirm}
              </Button>
            </DialogFooter>
          </DialogContent>
        ) : null}
      </Dialog>
    </div>
  );
}

/** The native kernel's layered agent definition: the trust switch (saved with the form), the files, the pipeline, load errors. */
function AgentSection({ projectId, trusted, onTrust }: { projectId: string; trusted: boolean; onTrust: (v: boolean) => void }) {
  const definition = useAgentDefinition(projectId);
  const d = definition.data;
  return (
    <section className="space-y-3" data-testid="project-agent">
      <h2 className="text-lg font-medium">{t.agentDefinition.title}</h2>
      <p className="text-muted-foreground text-xs">{t.agentDefinition.hint}</p>
      <div className="flex items-center justify-between gap-4">
        <div>
          <Label htmlFor="ps-trust-agent">{t.agentDefinition.trust}</Label>
          <p className="text-muted-foreground text-xs">{t.agentDefinition.trustHint}</p>
        </div>
        <Switch id="ps-trust-agent" checked={trusted} onCheckedChange={onTrust} />
      </div>
      {definition.isPending || !d ? (
        <Skeleton className="h-10 w-full" />
      ) : (
        <div className="space-y-3 text-sm">
          {!d.present ? <p className="text-muted-foreground">{t.agentDefinition.none}</p> : null}
          {d.files.length ? (
            <div>
              <p className="text-muted-foreground text-xs">{t.agentDefinition.files}</p>
              <ul className="font-mono text-xs">{d.files.map((f) => <li key={f}>{f}</li>)}</ul>
            </div>
          ) : null}
          {d.errors.length ? (
            <div>
              <p className="text-destructive text-xs">{t.agentDefinition.errors}</p>
              <ul className="text-destructive font-mono text-xs">{d.errors.map((e) => <li key={e}>{e}</li>)}</ul>
            </div>
          ) : null}
          {d.model ? (
            <p className="text-muted-foreground text-xs">{t.agentDefinition.model}: <span className="font-mono">{d.model}{d.effort ? ` · ${d.effort}` : ""}</span></p>
          ) : null}
          <div>
            <p className="text-muted-foreground text-xs">{t.agentDefinition.plugs}</p>
            <ol className="font-mono text-xs">{d.plugs.map((p, i) => <li key={`${p}-${i}`}>{p}</li>)}</ol>
          </div>
        </div>
      )}
    </section>
  );
}

/** The skills codex finds for the project — read-only, the files are the source. */
function SkillsSection({ projectId, rootPath }: { projectId: string; rootPath: string }) {
  const skills = useSkills(projectId);
  return (
    <section className="space-y-3" data-testid="project-skills">
      <h2 className="text-lg font-medium">{t.skills.title}</h2>
      <p className="text-muted-foreground text-xs">{t.skills.hint}</p>
      {skills.isPending ? (
        <Skeleton className="h-10 w-full" />
      ) : !skills.data || skills.data.length === 0 ? (
        <p className="text-muted-foreground text-sm">{t.skills.none}</p>
      ) : (
        <ul className="divide-y rounded-lg border">
          {skills.data.map((s) => {
            const where = skillOrigin(s.path, rootPath);
            return (
              <li key={s.path ?? s.name} className="flex flex-col gap-1 px-3 py-2">
                <span className="flex flex-wrap items-center gap-2">
                  <span className="shrink-0 whitespace-nowrap font-mono text-sm">${s.name}</span>
                  {where.kind === "project" ? (
                    <span className="text-muted-foreground min-w-0 truncate font-mono text-xs" title={s.path ?? undefined}>
                      {where.label}
                    </span>
                  ) : (
                    <Badge variant="outline" title={s.path ?? undefined}>
                      {where.label}
                    </Badge>
                  )}
                </span>
                <span className="text-muted-foreground text-sm">{s.shortDescription ?? s.description}</span>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}

// a project skill is shown by its path under the root; the others by where
// codex found them — their absolute paths say nothing: codex's built-in set
// (`<home>/skills/.system`), the user's global `~/.agents/skills`, or a skill
// codex's skill-installer put into this project's home (`<home>/skills`)
function skillOrigin(path: string | null, rootPath: string): { kind: "project" | "builtin" | "global" | "installed"; label: string } {
  if (path && path.startsWith(rootPath + "/")) return { kind: "project", label: path.slice(rootPath.length + 1) };
  if (path && path.includes("/skills/.system/")) return { kind: "builtin", label: t.skills.builtin };
  if (path && path.includes("/.agents/skills/")) return { kind: "global", label: t.skills.global };
  return { kind: "installed", label: t.skills.installed };
}
