import { useState, type FormEvent } from "react";
import { useNavigate } from "react-router";
import { RpcFailure, useCreateProject } from "@/core/projects";
import { Button } from "@/ui/components/ui/button";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { BottomBar, Page, TopBar } from "@/ui/shell/Shell";
import { t } from "@/ui/strings";

export function NewProjectPage() {
  const navigate = useNavigate();
  const create = useCreateProject();
  const [name, setName] = useState("");
  const [rootPath, setRootPath] = useState("");
  const [description, setDescription] = useState("");

  const fieldErrors = create.error instanceof RpcFailure ? create.error.fieldErrors() : {};
  const generalError =
    create.error && !(create.error instanceof RpcFailure && Object.keys(fieldErrors).length > 0)
      ? create.error.message
      : null;

  async function submit(e: FormEvent) {
    e.preventDefault();
    const project = await create.mutateAsync({ name, rootPath, description: description || undefined }).catch(() => null);
    if (project) navigate(`/p/${project.slug}`, { replace: true });
  }

  return (
    <>
      <TopBar title={t.newProject} back="/" />
      <Page>
        <form id="new-project" onSubmit={submit} className="flex max-w-lg flex-col gap-5" noValidate>
          <div className="grid gap-2">
            <Label htmlFor="name">{t.name}</Label>
            <Input
              id="name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              required
              autoComplete="off"
              aria-invalid={!!fieldErrors["name"]}
              className="h-11"
            />
            {fieldErrors["name"] ? <p className="text-destructive text-sm">{fieldErrors["name"]}</p> : null}
          </div>
          <div className="grid gap-2">
            <Label htmlFor="rootPath">{t.rootPath}</Label>
            <Input
              id="rootPath"
              value={rootPath}
              onChange={(e) => setRootPath(e.target.value)}
              required
              placeholder="/home/me/code/my-app"
              autoComplete="off"
              autoCapitalize="none"
              spellCheck={false}
              aria-invalid={!!fieldErrors["rootPath"]}
              className="h-11 font-mono"
            />
            {fieldErrors["rootPath"] ? <p className="text-destructive text-sm">{fieldErrors["rootPath"]}</p> : null}
          </div>
          <div className="grid gap-2">
            <Label htmlFor="description">{t.description}</Label>
            <Input id="description" value={description} onChange={(e) => setDescription(e.target.value)} className="h-11" />
          </div>
          {generalError ? <p role="alert" className="text-destructive text-sm">{generalError}</p> : null}
        </form>
      </Page>
      <BottomBar>
        <Button type="submit" form="new-project" size="lg" className="w-full lg:w-auto" disabled={create.isPending || !name || !rootPath}>
          {create.isPending ? t.creating : t.create}
        </Button>
      </BottomBar>
    </>
  );
}
