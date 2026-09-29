// The page's half of the PWA (mounted by the Shell, inside the router): the
// service worker registered or removed as the device chose (外观 → 离线缓存),
// a notification's click brought back as an in-app navigation, the notify
// feed raising a system notification while the page is out of sight
// (外观 → 系统通知) and the installed app's badge counting the threads that
// wait on the person; a page served as the offline shell reloads once the
// server answers again.
import { useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef } from "react";
import { useNavigate } from "react-router";
import { listRunningThreads } from "@/core/api";
import { usePreference } from "@/core/keys/preference";
import { joinNotify, notificationFor, shouldNotify, waitingCount } from "@/core/notify";
import { queryKeys, unwrap } from "@/core/projects";
import { getSocket } from "@/core/socket";
import {
  badgeSupported,
  notificationPermission,
  offlineCacheSupported,
  offlineShell,
  setBadge,
  showSystemNotification,
  syncServiceWorker,
  whenServerBack,
} from "./device";

// the worker fetches the app's files at install (1.6 MB compressed): not
// while the page's own first requests are on the wire
const REGISTER_AFTER_MS = 4_000;

export function PwaBridge({ prod = import.meta.env.PROD, registerAfterMs = REGISTER_AFTER_MS }: { prod?: boolean; registerAfterMs?: number }) {
  const navigate = useNavigate();
  const go = useRef(navigate);
  go.current = navigate;
  const offlineCache = usePreference("offlineCache");
  const notifications = usePreference("notifications");

  useEffect(() => {
    const timer = setTimeout(() => void syncServiceWorker(offlineCache, prod).catch(() => undefined), offlineCache ? registerAfterMs : 0);
    return () => clearTimeout(timer);
  }, [offlineCache, prod, registerAfterMs]);

  // the worker's notificationclick: the app is focused, the page moves there
  useEffect(() => {
    if (!offlineCacheSupported()) return;
    const onMessage = (e: MessageEvent<{ type?: string; url?: string }>) => {
      if (e.data?.type === "longx:navigate" && typeof e.data.url === "string") go.current(e.data.url);
    };
    const container = navigator.serviceWorker;
    container.addEventListener("message", onMessage);
    return () => container.removeEventListener("message", onMessage);
  }, []);

  useEffect(() => {
    if (!offlineShell()) return;
    return whenServerBack(() => window.location.reload());
  }, []);

  // the notify feed is joined on every page: it drives the badge, the system
  // notifications and the running-conversations query (the status strip's chip,
  // the picker, the welcome page — a slow poll otherwise), so an ask, a turn's
  // start or end shows within the event, not the poll
  const client = useQueryClient();
  useEffect(() => {
    const badge = badgeSupported();
    const changed = () => void client.invalidateQueries({ queryKey: queryKeys.running });
    const recount = () =>
      void listRunningThreads()
        .then(unwrap)
        .then((data) => setBadge(waitingCount((data as { threads: { waiting?: boolean }[] }).threads)))
        .catch(() => undefined);
    return joinNotify(getSocket(), {
      onRunning: (running) => {
        if (badge) setBadge(waitingCount(running));
        changed();
      },
      onEvent: (event) => {
        const page = { visible: document.visibilityState === "visible", focused: document.hasFocus() };
        if (notifications && notificationPermission() === "granted" && shouldNotify(page)) {
          void showSystemNotification(notificationFor(event), (url) => {
            window.focus();
            go.current(url);
          }).catch(() => undefined);
        }
        if (badge) recount();
        changed();
      },
    });
  }, [notifications, client]);

  return null;
}
