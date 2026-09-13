import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { useNavigate, useOutletContext } from "react-router";
import { toast } from "sonner";
import { archiveProject, clearCodexHistory, updateProject, type UpdateProjectInput } from "@/ash_rpc";
import { queryKeys, unwrap, useModels, useProject } from "@/core/projects";
import { Button } from "@/ui/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/ui/components/ui/dialog";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { RadioGroup, RadioGroupItem } from "@/ui/components/ui/radio-group";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/ui/components/ui/select";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { Switch } from "@/ui/components/ui/switch";
import { Textarea } from "@/ui/components/ui/textarea";
import type { ProjectContext } from "@/ui/frame/ProjectWindow";
import { t } from "@/ui/strings";

type Form = Required<Pick<UpdateProjectInput, "name" | "sandbox" | "approvalPolicy" | "networkAccess" | "dirtyStart">> & {
  description: string;
  memoryLimitMb: string;
  modelId: string;
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
  const [form, setForm] = useState<Form>({
    name: project.name,
    description: project.description ?? "",
    sandbox: project.sandbox,
    approvalPolicy: project.approvalPolicy,
    networkAccess: project.networkAccess,
    dirtyStart: project.dirtyStart,
    memoryLimitMb: project.memoryLimitMb ? String(project.memoryLimitMb) : "",
    modelId: "__default",
  });
  const [confirming, setConfirming] = useState<"clear" | "archive" | null>(null);
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
            sandbox: form.sandbox,
            approvalPolicy: form.approvalPolicy,
            networkAccess: form.networkAccess,
            dirtyStart: form.dirtyStart,
            memoryLimitMb: form.memoryLimitMb ? Number(form.memoryLimitMb) : null,
            modelId: form.modelId === "__default" ? null : form.modelId,
          },
        }),
      ),
    onSuccess: () => {
      toast.success(t.saved);
      client.invalidateQueries({ queryKey: queryKeys.project(slug) });
      client.invalidateQueries({ queryKey: queryKeys.projects });
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
            {(["untrusted", "on_request", "never"] as const).map((a) => (
              <div key={a} className="flex items-center gap-2">
                <RadioGroupItem value={a} id={`ps-approval-${a}`} />
                <Label htmlFor={`ps-approval-${a}`}>{t.approvalOptions[a]}</Label>
              </div>
            ))}
          </RadioGroup>
        </fieldset>
        <div className="flex items-center justify-between gap-4">
          <Label htmlFor="ps-network">{t.network}</Label>
          <Switch id="ps-network" checked={form.networkAccess} onCheckedChange={(v) => set("networkAccess", v)} />
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

      <section className="space-y-3">
        <h2 className="text-destructive text-lg font-medium">{t.dangerZone}</h2>
        <div className="flex flex-wrap gap-2">
          <Button variant="outline" onClick={() => setConfirming("clear")}>
            {t.clearCodexHistory}
          </Button>
          <Button variant="outline" onClick={() => setConfirming("archive")}>
            {t.archiveProject}
          </Button>
        </div>
        <p className="text-muted-foreground text-xs">{t.dangerHint}</p>
      </section>

      <Dialog open={confirming !== null} onOpenChange={(open) => (open ? null : setConfirming(null))}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{confirming === "clear" ? t.clearCodexHistory : t.archiveProject}</DialogTitle>
            <DialogDescription>{confirming === "clear" ? t.clearCodexHistoryHint : t.archiveProjectHint}</DialogDescription>
          </DialogHeader>
          <DialogFooter className="gap-2">
            <Button variant="ghost" onClick={() => setConfirming(null)}>
              {t.cancel}
            </Button>
            {confirming === "clear" ? (
              <Button variant="destructive" onClick={() => clear.mutate()} disabled={clear.isPending}>
                {t.confirmClear}
              </Button>
            ) : (
              <Button variant="destructive" onClick={() => archive.mutate()} disabled={archive.isPending}>
                {t.confirmArchive}
              </Button>
            )}
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
