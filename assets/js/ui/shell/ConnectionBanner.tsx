import { useEffect, useState } from "react";
import { onSocketStatus, socketStatus, type SocketStatus } from "@/core/socket";
import { t } from "@/ui/strings";

export function useSocketStatusValue(): SocketStatus {
  const [status, setStatus] = useState<SocketStatus>(socketStatus());
  useEffect(() => onSocketStatus(setStatus), []);
  return status;
}

/** Shown while the socket is down (a phone back from the background, a restart). */
export function ConnectionBanner({ status }: { status?: SocketStatus }) {
  const live = useSocketStatusValue();
  const current = status ?? live;
  if (current !== "closed") return null;
  return (
    <div
      role="status"
      data-testid="connection-banner"
      className="bg-warning/15 text-warning border-warning/30 border-b px-4 py-2 text-sm"
    >
      {t.connectionLost}
    </div>
  );
}
