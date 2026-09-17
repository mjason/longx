import { useState, type FormEvent } from "react";
import { useNavigate } from "react-router";
import { RpcFailure, useCreateProject } from "@/core/projects";
import { DirectoryPicker } from "@/ui/components/DirectoryPicker";
import { Button } from "@/ui/components/ui/button";
import { Checkbox } from "@/ui/components/ui/checkbox";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { BottomBar, Page, TopBar } from "@/ui/shell/Shell";
import { t } from "@/ui/strings";

type Step = "directory" | "details";

/**
 * One door for "new" and "open" (IDEA has two): pick a directory; if it is
 * already a repository that is an open, otherwise git can be set up on the
 * way. Two steps on every screen size.
 */
export function ProjectWizard() {
  const navigate = useNavigate();
  const create = useCreateProject();
  const [step, setStep] = useState<Step>("directory");
  const [dir, setDir] = useState<string | null>(null);
  const [dirIsRepo, setDirIsRepo] = useState(false);
  const [name, setName] = useState("");
  const [initGit, setInitGit] = useState(true);

  const fieldErrors = create.error instanceof RpcFailure ? create.error.fieldErrors() : {};
  const generalError = create.error && Object.keys(fieldErrors).length === 0 ? create.error.message : null;

  function chooseDirectory() {
    if (!dir) return;
    if (!name) setName(dir.split("/").filter(Boolean).pop() ?? "");
    setStep("details");
  }

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (!dir) return;
    const project = await create
      .mutateAsync({
        name,
        rootPath: dir,
        initGit: !dirIsRepo && initGit,
      })
      .catch(() => null);
    if (project) navigate(`/p/${project.slug}`, { replace: true });
  }

  if (step === "directory") {
    return (
      <>
        <TopBar title={t.chooseDirectory} back="/" />
        <Page>
          <p className="text-muted-foreground mb-3 text-sm">{t.chooseDirectoryHint}</p>
          <DirectoryPicker
            value={dir}
            onChange={(path, git) => {
              setDir(path);
              setDirIsRepo(git);
            }}
          />
        </Page>
        <BottomBar>
          <div className="flex w-full flex-col gap-1 lg:flex-row lg:items-center lg:gap-4">
            <span className="text-muted-foreground min-w-0 truncate font-mono text-xs" data-testid="chosen-directory">{dir ?? "—"}</span>
            <Button size="lg" className="w-full lg:ml-auto lg:w-auto" disabled={!dir} onClick={chooseDirectory}>
              {t.useThisDirectory}
            </Button>
          </div>
        </BottomBar>
      </>
    );
  }

  return (
    <>
      <TopBar title={t.details} back="/new" />
      <Page>
        <form id="project-details" onSubmit={submit} className="flex max-w-lg flex-col gap-5" noValidate>
          <div className="text-muted-foreground font-mono text-xs">{dir}</div>
          <div className="grid gap-2">
            <Label htmlFor="name">{t.name}</Label>
            <Input id="name" value={name} onChange={(e) => setName(e.target.value)} required autoComplete="off" aria-invalid={!!fieldErrors["name"]} className="h-11" />
            {fieldErrors["name"] ? <p className="text-destructive text-sm">{fieldErrors["name"]}</p> : null}
            {fieldErrors["rootPath"] ? <p className="text-destructive text-sm">{fieldErrors["rootPath"]}</p> : null}
          </div>

          {dirIsRepo ? (
            <p className="text-success text-sm">{t.alreadyRepo}</p>
          ) : (
            <label className="flex items-start gap-3 text-sm">
              <Checkbox checked={initGit} onCheckedChange={(v) => setInitGit(v === true)} className="mt-0.5" />
              <span>{t.initGitOption}</span>
            </label>
          )}

          {generalError ? <p role="alert" className="text-destructive text-sm">{generalError}</p> : null}
        </form>
      </Page>
      <BottomBar>
        <Button type="submit" form="project-details" size="lg" className="w-full lg:ml-auto lg:w-auto" disabled={create.isPending || !name}>
          {create.isPending ? t.creating : t.create}
        </Button>
      </BottomBar>
    </>
  );
}
