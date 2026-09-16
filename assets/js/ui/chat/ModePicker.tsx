import { Globe, ShieldAlert, ShieldCheck, ShieldOff } from "lucide-react";
import type { AccessMode } from "@/core/chat/adapter";
import { Label } from "@/ui/components/ui/label";
import { Popover, PopoverContent, PopoverTrigger } from "@/ui/components/ui/popover";
import { RadioGroup, RadioGroupItem } from "@/ui/components/ui/radio-group";
import { Switch } from "@/ui/components/ui/switch";
import { t } from "@/ui/strings";

const SANDBOXES: AccessMode["sandbox"][] = ["read_only", "workspace_write", "danger_full_access"];
const APPROVALS: AccessMode["approvalPolicy"][] = ["untrusted", "on_request", "never"];

export function modeIcon(sandbox: AccessMode["sandbox"]) {
  return sandbox === "danger_full_access" ? ShieldOff : sandbox === "read_only" ? ShieldCheck : ShieldAlert;
}

/**
 * The access mode for the next turn (Codex's "完全访问" chip): sandbox,
 * approval policy and network, from the composer rail. Codex keeps it for
 * the turns after, and the thread row records it.
 */
export function ModePicker({ mode, onChange, disabled = false, started = false }: { mode: AccessMode; onChange: (mode: AccessMode) => void; disabled?: boolean; started?: boolean }) {
  const Icon = modeIcon(mode.sandbox);
  const full = mode.sandbox === "danger_full_access";
  return (
    <Popover>
      <PopoverTrigger
        disabled={disabled}
        data-testid="mode-picker"
        aria-label={t.accessMode}
        className={`flex min-w-0 max-w-full items-center gap-1 rounded-md px-1.5 py-1 text-xs hover:bg-accent disabled:opacity-50 ${full ? "text-destructive" : "text-muted-foreground"}`}
      >
        <Icon className="size-3.5" />
        <span className="truncate">{t.sandboxOptions[mode.sandbox]}</span>
        {mode.networkAccess && mode.sandbox === "workspace_write" ? <Globe className="size-3" /> : null}
        {!mode.webSearch ? <span className="text-[10px]">{t.noWebSearch}</span> : null}
        {!mode.multiAgent ? <span className="text-[10px]">{t.noMultiAgent}</span> : null}
        {!mode.autoReview ? <span className="text-[10px]">{t.noAutoReview}</span> : null}
      </PopoverTrigger>
      <PopoverContent align="start" className="w-72 space-y-4" data-testid="mode-popover">
        <fieldset className="space-y-2">
          <legend className="text-xs font-medium">{t.sandbox}</legend>
          <RadioGroup value={mode.sandbox} onValueChange={(v) => onChange({ ...mode, sandbox: v as AccessMode["sandbox"] })}>
            {SANDBOXES.map((s) => (
              <div key={s} className="flex items-center gap-2">
                <RadioGroupItem value={s} id={`sandbox-${s}`} />
                <Label htmlFor={`sandbox-${s}`} className={s === "danger_full_access" ? "text-destructive" : ""}>
                  {t.sandboxOptions[s]}
                </Label>
              </div>
            ))}
          </RadioGroup>
        </fieldset>
        <fieldset className="space-y-2">
          <legend className="text-xs font-medium">{t.approval}</legend>
          <RadioGroup value={mode.approvalPolicy} onValueChange={(v) => onChange({ ...mode, approvalPolicy: v as AccessMode["approvalPolicy"] })}>
            {APPROVALS.map((a) => (
              <div key={a} className="flex items-center gap-2">
                <RadioGroupItem value={a} id={`approval-${a}`} />
                <Label htmlFor={`approval-${a}`}>{t.approvalOptions[a]}</Label>
              </div>
            ))}
          </RadioGroup>
        </fieldset>
        <div className="flex items-center justify-between gap-2">
          <Label htmlFor="mode-network" className="text-xs">
            {t.network}
          </Label>
          <Switch id="mode-network" checked={mode.networkAccess} disabled={mode.sandbox !== "workspace_write"} onCheckedChange={(v) => onChange({ ...mode, networkAccess: v })} />
        </div>
        <p className="text-muted-foreground text-xs">{t.networkHint}</p>
        <div className="flex items-center justify-between gap-2">
          <Label htmlFor="mode-web-search" className="text-xs">
            {t.webSearch}
          </Label>
          <Switch id="mode-web-search" checked={mode.webSearch} disabled={started} onCheckedChange={(v) => onChange({ ...mode, webSearch: v })} />
        </div>
        <div className="flex items-center justify-between gap-2">
          <Label htmlFor="mode-multi-agent" className="text-xs">
            {t.multiAgent}
          </Label>
          <Switch id="mode-multi-agent" checked={mode.multiAgent} disabled={started} onCheckedChange={(v) => onChange({ ...mode, multiAgent: v })} />
        </div>
        <div className="flex items-center justify-between gap-2">
          <Label htmlFor="mode-auto-review" className="text-xs">
            {t.autoReviewSwitch}
          </Label>
          <Switch id="mode-auto-review" checked={mode.autoReview} disabled={started} onCheckedChange={(v) => onChange({ ...mode, autoReview: v })} />
        </div>
        <p className="text-muted-foreground text-xs">{started ? t.modeHintStarted : t.modeHint}</p>
      </PopoverContent>
    </Popover>
  );
}
