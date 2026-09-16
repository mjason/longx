// The app updates from the Longx GitHub release (one release carries the
// server tarballs and the Android APK; the tag is the version of both).
export type ReleaseInfo = { tag: string; url: string; notes: string; apkName: string; apkUrl: string; apkSize: number };

export const LATEST_RELEASE_URL = "https://api.github.com/repos/mjason/longx/releases/latest";

/** whether `candidate` (v0.2.0, 0.1.9, v0.1.2-rc1) is newer than `current` */
export function newerVersion(candidate: string, current: string): boolean {
  const parse = (text: string) => {
    const core = text.trim().replace(/^v/, "").split(/[-+]/)[0]!;
    const parts = core.split(".").map((n) => (/^\d+$/.test(n) ? Number(n) : NaN));
    return parts.length && parts.every((n) => !Number.isNaN(n)) ? parts : null;
  };
  const a = parse(candidate);
  const b = parse(current);
  if (!a || !b) return false;
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i] ?? 0;
    const y = b[i] ?? 0;
    if (x !== y) return x > y;
  }
  return false;
}

/** the release out of GitHub's latest-release JSON; null without an .apk asset */
export function releaseFrom(json: unknown): ReleaseInfo | null {
  const r = json as { tag_name?: string; html_url?: string; body?: string; assets?: { name?: string; browser_download_url?: string; size?: number }[] };
  if (!r?.tag_name || !Array.isArray(r.assets)) return null;
  const apk = r.assets.find((a) => typeof a.name === "string" && a.name.endsWith(".apk"));
  if (!apk?.browser_download_url) return null;
  return { tag: r.tag_name, url: r.html_url ?? "", notes: r.body ?? "", apkName: apk.name!, apkUrl: apk.browser_download_url, apkSize: apk.size ?? 0 };
}
