// Self-update on Android: releases/latest of the Longx repository, the
// APK downloaded into the cache and handed to the package installer (the
// release key never changes, so it installs over the running app). iOS
// has no sideloading; the hook is a no-op there.
import Constants from "expo-constants";
import { Directory, File, Paths } from "expo-file-system";
import { getContentUriAsync } from "expo-file-system/legacy";
import * as IntentLauncher from "expo-intent-launcher";
import { useCallback, useEffect, useState } from "react";
import { Platform } from "react-native";
import { LATEST_RELEASE_URL, newerVersion, releaseFrom, type ReleaseInfo } from "./release";

export type UpdateStatus =
  | { kind: "idle" }
  | { kind: "checking" }
  | { kind: "upToDate" }
  | { kind: "available"; release: ReleaseInfo }
  | { kind: "downloading" }
  | { kind: "error"; message: string };

const CHECK_INTERVAL_MS = 6 * 60 * 60 * 1000;
let lastCheck = 0;

export async function fetchLatest(): Promise<ReleaseInfo | null> {
  const response = await fetch(LATEST_RELEASE_URL, { headers: { Accept: "application/vnd.github+json" } });
  if (!response.ok) return null;
  return releaseFrom(await response.json());
}

export function currentVersion(): string {
  return Constants.expoConfig?.version ?? "0.0.0";
}

export function useUpdater() {
  const [status, setStatus] = useState<UpdateStatus>({ kind: "idle" });

  const check = useCallback(async (force: boolean) => {
    if (Platform.OS !== "android") return;
    const now = Date.now();
    if (!force && now - lastCheck < CHECK_INTERVAL_MS) return;
    lastCheck = now;
    setStatus({ kind: "checking" });
    try {
      const release = await fetchLatest();
      setStatus(release && newerVersion(release.tag, currentVersion()) ? { kind: "available", release } : { kind: "upToDate" });
    } catch (e) {
      setStatus({ kind: "error", message: e instanceof Error ? e.message : String(e) });
    }
  }, []);

  const install = useCallback(async () => {
    if (status.kind !== "available") return;
    const { release } = status;
    setStatus({ kind: "downloading" });
    try {
      const dir = new Directory(Paths.cache, "updates");
      if (!dir.exists) dir.create();
      const target = new File(dir, release.apkName);
      if (target.exists) target.delete();
      const file = await File.downloadFileAsync(release.apkUrl, target);
      const uri = await getContentUriAsync(file.uri);
      await IntentLauncher.startActivityAsync("android.intent.action.VIEW", {
        data: uri,
        type: "application/vnd.android.package-archive",
        flags: 1, // FLAG_GRANT_READ_URI_PERMISSION
      });
      setStatus({ kind: "available", release });
    } catch (e) {
      setStatus({ kind: "error", message: e instanceof Error ? e.message : String(e) });
    }
  }, [status]);

  // a quiet check on mount, at most every six hours
  useEffect(() => {
    void check(false);
  }, [check]);

  return { status, check, install };
}
