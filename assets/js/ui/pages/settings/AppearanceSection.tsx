// 外观: the theme, and this device's own choices — the space menu, the
// reasoning's default, system notifications and the offline cache (both
// need a secure context: HTTPS, or localhost on the machine itself).
import { useState } from "react";
import { usePreference, setPreference, type Preference } from "@/core/keys/preference";
import { useTheme, type ThemePreference } from "@/core/theme";
import { Label } from "@/ui/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/ui/components/ui/select";
import { Switch } from "@/ui/components/ui/switch";
import { notificationPermission, notificationsSupported, offlineCacheSupported, requestNotifications } from "@/ui/pwa/device";
import { t } from "@/ui/strings";

export function AppearanceSection() {
  const { preference, setTheme } = useTheme();
  return (
    <div className="grid max-w-lg gap-6" data-testid="section-appearance">
      <div className="grid max-w-sm gap-2">
        <Label>{t.theme}</Label>
        <Select value={preference} onValueChange={(v) => setTheme(v as ThemePreference)}>
          <SelectTrigger className="h-11 w-full" aria-label={t.theme}>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {(["system", "dark", "light"] as const).map((k) => (
              <SelectItem key={k} value={k}>
                {t.themes[k]}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
      <DeviceChoices />
    </div>
  );
}

function DeviceChoices() {
  const s = t.pwa;
  const notifications = usePreference("notifications");
  const [denied, setDenied] = useState(notificationPermission() === "denied");
  const canNotify = notificationsSupported();
  const canCache = offlineCacheSupported();

  const toggleNotifications = async (on: boolean) => {
    if (!on) return setPreference("notifications", false);
    const answer = notificationPermission() === "granted" ? "granted" : await requestNotifications();
    setDenied(answer === "denied");
    setPreference("notifications", answer === "granted");
  };

  return (
    <div className="grid gap-4">
      <div>
        <h3 className="text-sm font-medium">{s.device}</h3>
        <p className="text-muted-foreground mt-0.5 text-xs">{s.deviceHint}</p>
      </div>
      <Choice id="pref-space-menu" name="spaceMenu" label={s.spaceMenu} hint={s.spaceMenuHint} />
      <Choice id="pref-reasoning-open" name="reasoningOpen" label={s.reasoningOpen} hint={s.reasoningOpenHint} />
      <Row
        id="pref-notifications"
        label={s.notifications}
        hint={!canNotify ? s.notificationsNeedHttps : denied ? s.notificationsDenied : s.notificationsHint}
        warn={!canNotify || denied}
        checked={canNotify && notifications && notificationPermission() === "granted"}
        disabled={!canNotify}
        onChange={(v) => void toggleNotifications(v)}
      />
      <Choice
        id="pref-offline-cache"
        name="offlineCache"
        label={s.offlineCache}
        hint={canCache ? s.offlineCacheHint : s.offlineCacheNeedsHttps}
        warn={!canCache}
        disabled={!canCache}
      />
    </div>
  );
}

function Choice({ id, name, label, hint, warn = false, disabled = false }: { id: string; name: Preference; label: string; hint: string; warn?: boolean; disabled?: boolean }) {
  const on = usePreference(name);
  return <Row id={id} label={label} hint={hint} warn={warn} checked={on && !disabled} disabled={disabled} onChange={(v) => setPreference(name, v)} />;
}

function Row({
  id,
  label,
  hint,
  warn,
  checked,
  disabled,
  onChange,
}: {
  id: string;
  label: string;
  hint: string;
  warn: boolean;
  checked: boolean;
  disabled: boolean;
  onChange: (on: boolean) => void;
}) {
  return (
    <div className="flex items-start justify-between gap-4">
      <div className="min-w-0">
        <label htmlFor={id} className="text-sm">
          {label}
        </label>
        <p className={`mt-0.5 text-xs ${warn ? "text-amber-600 dark:text-amber-400" : "text-muted-foreground"}`}>{hint}</p>
      </div>
      <Switch id={id} aria-label={label} checked={checked} disabled={disabled} onCheckedChange={onChange} />
    </div>
  );
}
