import { useTranslation } from "react-i18next";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Link, useNavigate, useOutletContext } from "react-router";
import { toast } from "sonner";
import { archiveProject, deleteProject, updateProject } from "@/core/api";
import type { UpdateProjectInput } from "@/gql/graphql";
import { agentKeys } from "@/core/agent";
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
import { ProjectWatches } from "./settings/ProjectWatches";
import { projectFileRules, useSaveProjectFileRules, type FileRules } from "@/core/fileRules";
import { FileRulesFields } from "@/ui/components/FileRulesFields";
import { ProjectExtensions } from "./settings/ProjectExtensions";
import { useSettingsCopy } from "./settings/copy";
import { useSettingsDraft } from "./settings/SettingsDraft";

type Form = {
  name: string;
  webSearch: boolean;
  trustLocalAgent: boolean;
  description: string;
  modelId: string;
  /** the kernel's parameters this project overrides ("" = inherit) */
  agentOverrides: AgentSettingsForm;
};

/**
 * The project's settings: what every new thread starts with (web search,
 * model), the agent definition, and the danger zone.
 * Thread-level overrides live in the composer rail.
 */
export function ProjectSettingsPage({ section = "project" }: { section?: string }) {
  const ctx = useOutletContext<ProjectContext>();
  const project = useProject(ctx.slug);
  if (project.isPending) return <Skeleton className="m-4 h-40" data-testid="chat-area" />;
  if (project.isError) return <p className="text-destructive p-4">{project.error.message}</p>;
  return <SettingsForm key={`${project.data.updatedAt}-${section}`} section={section} project={project.data} slug={ctx.slug} />;
}

type Project = NonNullable<ReturnType<typeof useProject>["data"]>;

function SettingsForm({ project, slug, section }: { project: Project; slug: string; section: string }) {
    useTranslation();
  // the .longx files, for the watches card to point at shared ones the trust switch keeps off
  const definitionFiles = useAgentDefinition(project.id);
  const client = useQueryClient();
  const navigate = useNavigate();
  const models = useModels();
  const initial: Form = {
    name: project.name,
    description: project.description ?? "",
    webSearch: project.webSearch,
    trustLocalAgent: project.trustLocalAgent,
    modelId: project.modelId ?? "__default",
    agentOverrides: agentSettingsForm((project.agentSettings ?? {}) as Parameters<typeof agentSettingsForm>[0]),
  };
  const [form, setForm] = useState<Form>(initial);
  const copy = useSettingsCopy();
  const [saved, setSaved] = useState(false);
  useSettingsDraft(!saved && JSON.stringify(form) !== JSON.stringify(initial));
  const [confirming, setConfirming] = useState<"archive" | "delete" | null>(null);
  const set = <K extends keyof Form>(key: K, value: Form[K]) => { setSaved(false); setForm((f) => ({ ...f, [key]: value })); };

  const save = useMutation({
    mutationFn: async () =>
      unwrap(
        await updateProject({
          identity: project.id,
          input: section === "agent" || section === "resources" ? {
            agentSettings: agentSettingsInput(form.agentOverrides),
          } : section === "extensions" ? {
            trustLocalAgent: form.trustLocalAgent,
          } : {
            name: form.name,
            description: form.description || null,
            webSearch: form.webSearch,
            modelId: form.modelId === "__default" ? null : form.modelId,
          },
        }),
      ),
    onSuccess: () => {
      setSaved(true);
      toast.success(t.saved);
      client.invalidateQueries({ queryKey: queryKeys.project(slug) });
      client.invalidateQueries({ queryKey: queryKeys.projects });
      client.invalidateQueries({ queryKey: ["project", project.id, "agent-definition"] });
      client.invalidateQueries({ queryKey: agentKeys.all });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const archive = useMutation({
    mutationFn: async () => unwrap(await archiveProject({ identity: project.id })),
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
      {section === "project" ? <>
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
      </section>
      </> : null}

      {["agent", "resources", "extensions"].includes(section) ? <AgentSection section={section} projectId={project.id} trusted={form.trustLocalAgent} onTrust={(v) => set("trustLocalAgent", v)} overrides={form.agentOverrides} onOverrides={(v) => set("agentOverrides", v)} /> : null}

      {["project", "agent", "resources", "extensions"].includes(section) ? <Button className="self-start" onClick={() => save.mutate()} disabled={save.isPending}>{copy.saveProject}</Button> : null}
      {section === "extensions" ? <ProjectExtensions projectId={project.id} /> : null}

      {section === "files" ? <ProjectFileRules projectId={project.id} slug={slug} initial={projectFileRules(project.fileRules)} /> : null}
      {section === "watches" ? <ProjectWatches projectId={project.id} rootPath={project.rootPath} trusted={project.trustLocalAgent} sharedFiles={definitionFiles.data?.files ?? []} /> : null}

      {section === "project" ? (
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
      ) : null}

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

/** What `plug Browser` resolves to, in words: the browser's name with its state, or why there is none. */
function browserStateLabel(b: { state: string; browser: string | null }): string {
  const label = t.agentDefinition.browserState[b.state];
  if (typeof label === "function") return label(b.browser ?? "");
  return label ?? b.state;
}

/**
 * The kernel's layered agent definition: the trust switch and the
 * kernel overrides (saved with the form), the declared agents, the files,
 * the local files to promote, the pipeline, load errors.
 */
function AgentSection({
  section,
  projectId,
  trusted,
  onTrust,
  overrides,
  onOverrides,
}: {
  section: string;
  projectId: string;
  trusted: boolean;
  onTrust: (v: boolean) => void;
  overrides: AgentSettingsForm;
  onOverrides: (v: AgentSettingsForm) => void;
}) {
    useTranslation();
  const definition = useAgentDefinition(projectId);
  const models = useModelRows();
  const copy = useSettingsCopy();
  const d = definition.data;
  return (
    <section className="space-y-3" data-testid="project-agent">
      {section === "extensions" ? <>
      <h2 className="text-lg font-medium">{t.agentDefinition.title}</h2>
      <div className="flex items-center justify-between gap-4">
        <div>
          <Label htmlFor="ps-trust-agent">{t.agentDefinition.trust}</Label>
          <p className="text-muted-foreground text-xs">{copy.trustScope}</p>
          <details className="text-muted-foreground text-xs">
            <summary className="cursor-pointer">{t.agentDefinition.title}</summary>
            <p className="mt-2">{t.agentDefinition.trustHint}</p>
            <p className="mt-2">{t.agentDefinition.hint}</p>
          </details>
        </div>
        <Switch id="ps-trust-agent" checked={trusted} onCheckedChange={onTrust} />
      </div>
      </> : null}
      {definition.isPending || !d ? (
        <Skeleton className="h-10 w-full" />
      ) : (
        <div className="space-y-3 text-sm">
          {section === "extensions" ? <>
          <details className="rounded-lg border p-3">
          <summary className="cursor-pointer text-sm">{copy.realStatus}{d.errors.length ? ` (${d.errors.length})` : ""}</summary>
          <div className="mt-3 space-y-3">
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
          {d.errors.length ? (
            <div>
              <p className="text-destructive text-xs">{t.agentDefinition.errors}</p>
              <ul className="text-destructive font-mono text-xs">{d.errors.map((e) => <li key={e}>{e}</li>)}</ul>
            </div>
          ) : null}
          {d.model ? (
            <p className="text-muted-foreground text-xs">{t.agentDefinition.model}: <span className="font-mono">{d.model}{d.effort ? ` · ${d.effort}` : ""}</span></p>
          ) : null}
          <div className="text-muted-foreground text-xs">
            <p>{t.agentDefinition.plugs}</p>
            <ol className="break-all font-mono">{d.plugs.map((plug, i) => <li key={`${i}-${plug}`}>{plug}</li>)}</ol>
          </div>
          {d.browser ? (
            <p className="text-muted-foreground text-xs" data-testid="project-browser">
              {t.agentDefinition.browser}: <span className="font-mono">{d.browser.alias ?? t.agentDefinition.browserDefault}</span>
              {" · "}
              <span className={d.browser.state === "online" ? "text-foreground" : "text-amber-600 dark:text-amber-400"}>{browserStateLabel(d.browser)}</span>
              {" · "}{t.agentDefinition.browserTabs(d.browser.maxTabs)}
              {" · "}<Link to="?scope=global&section=browsers" className="underline underline-offset-2">{t.agentDefinition.browserSettings}</Link>
            </p>
          ) : null}
          </div>
          </details>
          </> : null}
          {section !== "extensions" ? (
          <div className="space-y-2 rounded-lg border p-3" data-testid="project-agent-overrides">
            <p className="text-sm font-medium">{t.agentDefinition.overrides}</p>
            <p className="text-muted-foreground text-xs">{t.agentDefinition.overridesHint}</p>
            <AgentSettingsFields idPrefix="ps-ak" value={overrides} onChange={onOverrides} models={models.data ?? []} inherited={d.settings} group={section === "resources" ? "resources" : "collaboration"} />
          </div>
          ) : null}
        </div>
      )}
    </section>
  );
}

/** the project's own ignore / watch rules, saved on their own (the watcher reloads) */
function ProjectFileRules({ projectId, slug, initial }: { projectId: string; slug: string; initial: FileRules }) {
    useTranslation();
  const [value, setValue] = useState(initial);
  useSettingsDraft(JSON.stringify(value) !== JSON.stringify(initial));
  const save = useSaveProjectFileRules(projectId, slug);
  const dirty = value.ignore !== initial.ignore || value.watch !== initial.watch;
  return (
    <section className="space-y-4" data-testid="project-file-rules">
      <h2 className="text-lg font-medium">{t.fileRules.project}</h2>
      <p className="text-muted-foreground text-sm">{t.fileRules.projectHint}</p>
      <FileRulesFields idPrefix="ps-rules" value={value} onChange={setValue} />
      <Button
        variant="outline"
        disabled={!dirty || save.isPending}
        onClick={() => save.mutate(value, { onSuccess: () => toast.success(t.saved), onError: (e: Error) => toast.error(e.message) })}
      >
        {t.fileRules.save}
      </Button>
    </section>
  );
}
