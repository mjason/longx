const OS_LABELS: Record<string, string> = { mac: "macOS", win: "Windows", linux: "Linux", cros: "ChromeOS", android: "Android" };

/** Browsers cannot read the computer's hostname; use a persistent ID suffix. */
export function generatedDeviceName(installId: string, os: string, ua: string): string {
  const major = /Chrom(?:e|ium)\/(\d+)/.exec(ua)?.[1];
  return `${major ? `Chrome ${major}` : "Chrome"} · ${OS_LABELS[os] ?? os} · ${installId.slice(-6)}`;
}

export function normalizeDeviceName(name: string): string {
  const normalized = name.trim();
  if (!normalized || normalized.length > 80 || /[\u0000-\u001f\u007f]/u.test(normalized)) {
    throw new Error("设备名称需要 1–80 个字符，不能包含换行或控制字符。");
  }
  return normalized;
}
