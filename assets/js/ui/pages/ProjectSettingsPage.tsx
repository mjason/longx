import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { useNavigate, useOutletContext } from "react-router";
import { toast } from "sonner";
import { archiveProject, deleteProject, updateProject, type UpdateProjectInput } from "@/ash_rpc";
import { usePromoteLocal } from "@/core/agent";
import { useModelRows } from "@/core/ai";
import { queryKeys, unwrap, useAgentDefinition, useModels, useProject } from "@/core/projects";
import { AgentSettingsFields, agentSettingsForm, agentSettingsInput, type AgentSettingsForm } from "@/ui/components/AgentSettingsFields";
import { Button } from "@/ui/components/ui/button";
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

type Form = Required<Pick<UpdateProjectInput, "name" | "webSearch" | "dirtyStart" | "trustLocalAgent">> & {
  description: string;
  modelId: string;
  /** the kernel's parameters this project overrides ("" = inherit) */
  agentOverrides: AgentSettingsForm;
};

/**
 * The project's settings: what every new thread starts with (web search,
 * dirty-tree policy, model), the agent definition, and the danger zone.
 * Thread-level overrides live in the composer rail.
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
  const [form, setForm] = useState<Form>({
    name: project.name,
    description: project.description ?? "",
    webSearch: project.webSearch,
    dirtyStart: project.dirtyStart,
    trustLocalAgent: project.trustLocalAgent,
    modelId: project.modelId ?? "__default",
    agentOverrides: agentSettingsForm((project.agentSettings ?? {}) as Parameters<typeof agentSettingsForm>[0]),
  });
  const [confirming, setConfirming] = useState<"archive" | "delete" | null>(null);
  const set = <K extends keyof Form>(key: K, value: Form[K]) => setForm((f) => ({ ...f, [key]: value }));

  const save = useMutation({
    mutationFn: async () =>
      unwrap(
        await updateProject({
          identity: project.id,
          fields: ["id"],
          input: {
            name: form.name,
            description: form.description || null,
            webSearch: form.webSearch,
            dirtyStart: form.dirtyStart,
            trustLocalAgent: form.trustLocalAgent,
            modelId: form.modelId === "__default" ? null : form.modelId,
            agentSettings: agentSettingsInput(form.agentOverrides),
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

  const archive = useMutation({
    mutationFn: async () => unwrap(await archiveProject({ identity: project.id, fields: ["id"] })),
    onSuccess: () => {
      client.invalidateQueries({ queryKey: queryKeys.projects });
      navigate("/");
    },
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
        <div className="flex items-center justify-between gap-4">
          <Label htmlFor="ps-web-search">{t.webSearch}</Label>
          <Switch id="ps-web-search" checked={form.webSearch} onCheckedChange={(v) => set("webSearch", v)} />
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
        <Button onClick={() => save.mutate()} disabled={save.isPending}>
          {t.save}
        </Button>
      </section>

      <AgentSection projectId={project.id} trusted={form.trustLocalAgent} onTrust={(v) => set("trustLocalAgent", v)} overrides={form.agentOverrides} onOverrides={(v) => set("agentOverrides", v)} />

      <section className="space-y-3">
        <h2 className="text-destructive text-lg font-medium">{t.dangerZone}</h2>
        <p className="text-muted-foreground text-xs">{t.dangerHint}</p>
        <div className="flex flex-wrap gap-2">
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

/**
 * The kernel's layered agent definition: the trust switch and the
 * kernel overrides (saved with the form), the declared agents, the files,
 * the local files to promote, the pipeline, load errors.
 */
function AgentSection({
  projectId,
  trusted,
  onTrust,
  overrides,
  onOverrides,
}: {
  projectId: string;
  trusted: boolean;
  onTrust: (v: boolean) => void;
  overrides: AgentSettingsForm;
  onOverrides: (v: AgentSettingsForm) => void;
}) {
  const definition = useAgentDefinition(projectId);
  const models = useModelRows();
  const promote = usePromoteLocal(projectId);
  const d = definition.data;
  const promoteFile = (path: string) =>
    promote.mutate(path, { onSuccess: (r) => toast.success(t.agentDefinition.promoted(r.path)), onError: (e: Error) => toast.error(e.message) });
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
          <div>
            <p className="text-muted-foreground text-xs">{t.agentDefinition.agents}</p>
            <ul className="text-xs" data-testid="project-agents">
              {d.agents.map((a) => (
                <li key={a.name} className="flex flex-wrap items-baseline gap-2">
                  <span className="font-mono">{a.name}</span>
                  <Badge variant="outline">{t.agentDefinition.agentLayer[a.layer] ?? a.layer}</Badge>
                  <span className="text-muted-foreground">{a.summary}</span>
                </li>
              ))}
            </ul>
          </div>
          {d.localFiles.length ? (
            <div>
              <p className="text-muted-foreground text-xs">{t.agentDefinition.localFiles}</p>
              <ul className="font-mono text-xs" data-testid="project-local-files">
                {d.localFiles.map((f) => (
                  <li key={f} className="flex items-center justify-between gap-2 py-0.5">
                    <span>{f}</span>
                    <Button size="sm" variant="outline" onClick={() => promoteFile(f)} disabled={promote.isPending}>{t.agentDefinition.promote}</Button>
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
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
          <div className="space-y-2 rounded-lg border p-3" data-testid="project-agent-overrides">
            <p className="text-sm font-medium">{t.agentDefinition.overrides}</p>
            <p className="text-muted-foreground text-xs">{t.agentDefinition.overridesHint}</p>
            <AgentSettingsFields idPrefix="ps-ak" value={overrides} onChange={onOverrides} models={models.data ?? []} inherited={d.settings} />
          </div>
        </div>
      )}
    </section>
  );
}
