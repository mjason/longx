// Settings → 移动端: the code a phone pairs with (one-time, ten minutes),
// the address it should type (this page's origin), the paired devices with
// a revoke — Longx.System.Device over RPC.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Smartphone, Trash2 } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";
import { listDevices, pairingCode, revokeDevice } from "@/ash_rpc";
import { relativeTime } from "@/core/format";
import { unwrap } from "@/core/projects";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/ui/components/ui/alert-dialog";
import { Button } from "@/ui/components/ui/button";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { t } from "@/ui/strings";

const s = t.mobilePage;

export type Device = {
  id: string;
  name: string;
  platform: "android" | "ios" | "other";
  lastSeenAt: string | null;
  insertedAt: string;
};

const devicesKey = ["devices"] as const;

export function useDevices() {
  return useQuery({
    queryKey: devicesKey,
    queryFn: async () =>
      unwrap(await listDevices({ fields: ["id", "name", "platform", "lastSeenAt", "insertedAt"] })) as Device[],
  });
}

export function MobileSection() {
  const client = useQueryClient();
  const devices = useDevices();
  const [code, setCode] = useState<{ code: string; expiresAt: string } | null>(null);
  const [confirm, setConfirm] = useState<Device | null>(null);
  const fail = (e: unknown) => toast.error(e instanceof Error ? e.message : String(e));

  const generate = useMutation({
    mutationFn: async () => unwrap(await pairingCode({ fields: ["code", "expiresAt"] })),
    onSuccess: (r) => setCode({ code: r.code, expiresAt: r.expiresAt }),
    onError: fail,
  });
  const revoke = useMutation({
    mutationFn: async (d: Device) => unwrap(await revokeDevice({ identity: d.id })),
    onSuccess: () => client.invalidateQueries({ queryKey: devicesKey }),
    onError: fail,
  });

  return (
    <section className="space-y-6" data-testid="section-mobile">
      <div className="space-y-3">
        <h2 className="text-base font-medium">{s.pairTitle}</h2>
        <p className="text-muted-foreground text-sm">{s.pairHint}</p>
        <div className="rounded-lg border p-4">
          <p className="text-muted-foreground text-xs">{s.address}</p>
          <p className="font-mono text-sm">{location.host}</p>
          {code ? (
            <>
              <p className="text-muted-foreground mt-3 text-xs">{s.code}</p>
              <p className="font-mono text-3xl tracking-[0.3em]">{code.code}</p>
              <p className="text-muted-foreground text-xs">{s.expires}</p>
            </>
          ) : null}
          <Button className="mt-3" variant={code ? "outline" : "default"} onClick={() => generate.mutate()} disabled={generate.isPending}>
            {code ? s.regenerate : s.generate}
          </Button>
        </div>
      </div>

      <div className="space-y-3">
        <h2 className="text-base font-medium">{s.devicesTitle}</h2>
        {devices.isPending ? (
          <Skeleton className="h-12 w-full" />
        ) : devices.isError ? (
          <p className="text-destructive text-sm">{devices.error.message}</p>
        ) : devices.data.length === 0 ? (
          <p className="text-muted-foreground text-sm">{s.none}</p>
        ) : (
          <ul className="divide-y rounded-lg border">
            {devices.data.map((d) => (
              <li key={d.id} className="flex items-center gap-3 px-3 py-2">
                <Smartphone className="text-muted-foreground size-4 shrink-0" />
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm">{d.name}</p>
                  <p className="text-muted-foreground text-xs">
                    {s.platforms[d.platform]} · {d.lastSeenAt ? s.seen(relativeTime(d.lastSeenAt)) : s.neverSeen}
                  </p>
                </div>
                <Button variant="ghost" size="icon" className="size-8 shrink-0" aria-label={s.revoke} onClick={() => setConfirm(d)}>
                  <Trash2 className="size-4" />
                </Button>
              </li>
            ))}
          </ul>
        )}
      </div>

      <AlertDialog open={confirm !== null} onOpenChange={(o) => (o ? null : setConfirm(null))}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{s.revokeTitle(confirm?.name ?? "")}</AlertDialogTitle>
            <AlertDialogDescription>{s.revokeHint}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t.cancel}</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                if (confirm) revoke.mutate(confirm);
                setConfirm(null);
              }}
            >
              {s.revokeConfirm}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </section>
  );
}
