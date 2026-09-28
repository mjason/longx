// The text prompt the space menu's commands open (core/keys/prompt).
import { useEffect, useState } from "react";
import { closePrompt, usePrompt } from "@/core/keys/prompt";
import { Button } from "@/ui/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/ui/components/ui/dialog";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { t } from "@/ui/strings";

export function PromptDialog() {
  const request = usePrompt();
  const [value, setValue] = useState("");
  useEffect(() => setValue(request?.value ?? ""), [request]);
  const submit = () => {
    const trimmed = value.trim();
    if (!request || trimmed === "") return;
    const onSubmit = request.onSubmit;
    closePrompt();
    onSubmit(trimmed);
  };
  return (
    <Dialog open={request !== null} onOpenChange={(open) => (open ? null : closePrompt())}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{request?.title ?? ""}</DialogTitle>
          <DialogDescription className="sr-only">{request?.label ?? ""}</DialogDescription>
        </DialogHeader>
        <form
          className="grid gap-3"
          onSubmit={(e) => {
            e.preventDefault();
            submit();
          }}
        >
          <Label htmlFor="keys-prompt">{request?.label}</Label>
          <Input id="keys-prompt" value={value} onChange={(e) => setValue(e.target.value)} autoFocus />
          <DialogFooter>
            <Button type="button" variant="outline" onClick={closePrompt}>
              {t.cancel}
            </Button>
            <Button type="submit" disabled={value.trim() === ""}>
              {request?.submit}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
