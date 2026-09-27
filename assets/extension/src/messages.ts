// What the popup and the service worker say to each other (chrome.runtime
// messages). Types only: nothing here is shared at run time, so the two
// entries build to two files with no chunk between them.
import type { BridgeStatus, SessionInfo } from "./relay";

export type PopupStatus = BridgeStatus | "disconnected";

export type PopupMessage = { type: "status" } | { type: "connect"; serverUrl: string } | { type: "disconnect" };

/** the worker's answer: the status, or why the request itself was bad (an address that is no URL) */
export type PopupReply = StatusReport | { failed: string };

export interface StatusReport {
  status: PopupStatus;
  name: string | null;
  serverUrl: string | null;
  sessions: SessionInfo[];
  error: string | null;
}
