import { useTranslation } from "react-i18next";
// Logging a ChatGPT subscription in (the `chatgpt` preset's OAuth2
// credential): the device code first — a short code to type at OpenAI's
// page, no port, no address to catch, Longx polling until it is done —
// and the browser way beneath it for whoever prefers: the login page opens,
// the browser ends on an unreachable localhost:1455 address, and the person
// pastes that address back (Longx.Credentials.OAuth.complete_url).
import { Check, ExternalLink, Loader2 } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { toast } from "sonner";
import { useCredentialActions } from "@/core/credentials";
import { Button } from "@/ui/components/ui/button";
import { Dialog, DialogBody, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/ui/components/ui/dialog";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { t } from "@/ui/strings";

const s = t.chatgptLogin;

export function ChatGptLoginDialog({ credentialId, onClose }: { credentialId: string; onClose: () => void }) {
    useTranslation();
  const actions = useCredentialActions();
  // Opening this dialog is an explicit new login, even if the old token
  // still looks ready locally (it may have been revoked upstream).
  const [loggedIn, setLoggedIn] = useState(false);
  const [device, setDevice] = useState<{ state: string; userCode: string; verificationUrl: string; interval: number } | null>(null);
  const [deviceError, setDeviceError] = useState<string | null>(null);
  const [browser, setBrowser] = useState<{ url: string; redirectUri: string } | null>(null);
  const [pasted, setPasted] = useState("");
  const [attempt, setAttempt] = useState(0);
  const generation = useRef(0);

  // the device code, asked for as soon as the dialog opens
  useEffect(() => {
    const current = ++generation.current;
    setLoggedIn(false);
    setDevice(null);
    setDeviceError(null);
    actions.deviceBegin.mutate(credentialId, {
      onSuccess: (d) => { if (generation.current === current) setDevice(d); },
      onError: (e) => { if (generation.current === current) setDeviceError(e.message); },
    });
    return () => { generation.current++; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [credentialId, attempt]);

  // polling at the vendor's interval until the person typed the code
  useEffect(() => {
    if (!device || loggedIn) return;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout>;
    const poll = async () => {
      try {
        const r = await actions.devicePoll.mutateAsync(device.state);
        if (cancelled) return;
        if (r.status === "ok") setLoggedIn(true);
        else if (r.status === "error") setDeviceError(r.message ?? s.failed);
        else schedule();
      } catch (e) {
        if (!cancelled) setDeviceError(e instanceof Error ? e.message : s.failed);
      }
    };
    const schedule = () => { timer = setTimeout(() => void poll(), Math.max(device.interval, 1) * 1000); };
    schedule();
    return () => { cancelled = true; clearTimeout(timer); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [device?.state, loggedIn]);

  const openBrowser = () => {
    actions.loginUrl.mutate(
      { id: credentialId, origin: typeof window === "undefined" ? null : window.location.origin },
      {
        onSuccess: (r) => {
          setBrowser({ url: r.url, redirectUri: r.redirectUri });
          window.open(r.url, "_blank", "noopener");
        },
        onError: (e) => toast.error(e.message),
      },
    );
  };

  const completePasted = () => {
    actions.completeUrl.mutate(pasted.trim(), {
      onSuccess: () => { setLoggedIn(true); toast.success(s.loggedIn); },
      onError: (e) => toast.error(e.message),
    });
  };

  return (
    <Dialog open onOpenChange={(o) => (o ? null : onClose())}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{s.title}</DialogTitle>
          <DialogDescription>{s.hint}</DialogDescription>
        </DialogHeader>
        <DialogBody className="flex flex-col gap-5">
          {loggedIn ? (
            <div className="flex items-center gap-2 text-sm" data-testid="chatgpt-logged-in">
              <Check className="size-4 text-emerald-500" /> {s.loggedIn}
            </div>
          ) : (
            <section className="flex flex-col gap-2">
              <h3 className="text-sm font-medium">{s.deviceTitle}</h3>
              {deviceError ? (
                <>
                  <p className="text-destructive text-sm" role="alert">{deviceError}</p>
                  <div><Button type="button" variant="outline" size="sm" onClick={() => setAttempt((n) => n + 1)}>{s.retryDevice}</Button></div>
                </>
              ) : device ? (
                <>
                  <p className="text-muted-foreground text-sm">{s.deviceHint}</p>
                  <div className="flex flex-wrap items-center gap-3">
                    <code className="bg-muted rounded-md px-3 py-2 font-mono text-xl tracking-widest" data-testid="device-code">{device.userCode}</code>
                    <a href={device.verificationUrl} target="_blank" rel="noreferrer" className="text-primary inline-flex items-center gap-1 text-sm underline-offset-4 hover:underline">
                      {device.verificationUrl} <ExternalLink className="size-3" />
                    </a>
                  </div>
                  <p className="text-muted-foreground flex items-center gap-1.5 text-xs">
                    <Loader2 className="size-3 animate-spin" /> {s.waiting}
                  </p>
                </>
              ) : (
                <p className="text-muted-foreground flex items-center gap-1.5 text-sm">
                  <Loader2 className="size-3 animate-spin" /> {s.asking}
                </p>
              )}
            </section>
          )}
          {!loggedIn ? (
            <section className="flex flex-col gap-2 border-t pt-4">
              <h3 className="text-sm font-medium">{s.browserTitle}</h3>
              <p className="text-muted-foreground text-sm">{s.browserHint}</p>
              {browser ? (
                <>
                  <p className="text-muted-foreground text-xs">{s.pasteHint(browser.redirectUri)}</p>
                  <div className="flex flex-col gap-1.5">
                    <Label htmlFor="chatgpt-pasted">{s.pasteLabel}</Label>
                    <Input id="chatgpt-pasted" value={pasted} onChange={(e) => setPasted(e.target.value)} placeholder="http://localhost:1455/auth/callback?code=…&state=…" className="font-mono text-xs" />
                  </div>
                  <div>
                    <Button type="button" size="sm" disabled={!pasted.trim() || actions.completeUrl.isPending} onClick={completePasted}>
                      {s.completePasted}
                    </Button>
                  </div>
                </>
              ) : (
                <div>
                  <Button type="button" variant="outline" size="sm" disabled={actions.loginUrl.isPending} onClick={openBrowser}>
                    {s.useBrowser}
                  </Button>
                </div>
              )}
            </section>
          ) : null}
        </DialogBody>
        <DialogFooter>
          <Button type="button" variant={loggedIn ? "default" : "outline"} onClick={onClose}>
            {loggedIn ? t.done : t.close}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
