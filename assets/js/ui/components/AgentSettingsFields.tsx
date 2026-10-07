// The native kernel's team parameters as form fields — the global page and
// a project's overrides share them (a project leaves a field empty to inherit).
import type { ModelRow } from "@/core/ai";
import { useAgentSettings } from "@/core/agent";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/ui/components/ui/select";
import { t } from "@/ui/strings";
import { Button } from "@/ui/components/ui/button";
import { useSettingsCopy } from "@/ui/pages/settings/copy";

const s = t.agentKernel;

/** Every value as the form holds it: a string ("" = inherit / unset). */
export type AgentSettingsForm = {
  maxDepth: string;
  maxChildren: string;
  idleMinutes: string;
  modelRetries: string;
  commandOomPriority: string;
  memoryFloorPercent: string;
  commandCgroupMode: string;
  commandMemoryLimitPercent: string;
  commandSwapLimitMb: string;
  childModel: string;
  childEffort: string;
};

export const emptyAgentSettingsForm: AgentSettingsForm = {
  maxDepth: "",
  maxChildren: "",
  idleMinutes: "",
  modelRetries: "",
  commandOomPriority: "",
  memoryFloorPercent: "",
  commandCgroupMode: "",
  commandMemoryLimitPercent: "",
  commandSwapLimitMb: "",
  childModel: "",
  childEffort: "",
};

/** The form as the RPC wants it: numbers, nulls for the empty. */
export function agentSettingsInput(form: AgentSettingsForm) {
  const num = (v: string) => (v.trim() === "" ? null : Number(v));
  const str = (v: string) => (v.trim() === "" ? null : v.trim());
  return {
    maxDepth: num(form.maxDepth),
    maxChildren: num(form.maxChildren),
    idleMinutes: num(form.idleMinutes),
    modelRetries: num(form.modelRetries),
    commandOomPriority: num(form.commandOomPriority),
    memoryFloorPercent: num(form.memoryFloorPercent),
    commandCgroupMode: str(form.commandCgroupMode),
    commandMemoryLimitPercent: num(form.commandMemoryLimitPercent),
    commandSwapLimitMb: num(form.commandSwapLimitMb),
    childModel: str(form.childModel),
    childEffort: str(form.childEffort),
  };
}

export function agentSettingsForm(values: Partial<Record<keyof AgentSettingsForm, number | string | null | undefined>>): AgentSettingsForm {
  const one = (v: number | string | null | undefined) => (v === null || v === undefined ? "" : String(v));
  return {
    maxDepth: one(values.maxDepth),
    maxChildren: one(values.maxChildren),
    idleMinutes: one(values.idleMinutes),
    modelRetries: one(values.modelRetries),
    commandOomPriority: one(values.commandOomPriority),
    memoryFloorPercent: one(values.memoryFloorPercent),
    commandCgroupMode: one(values.commandCgroupMode),
    commandMemoryLimitPercent: one(values.commandMemoryLimitPercent),
    commandSwapLimitMb: one(values.commandSwapLimitMb),
    childModel: one(values.childModel),
    childEffort: one(values.childEffort),
  };
}

const NONE = "__none";

export function AgentSettingsFields({
  idPrefix,
  value,
  onChange,
  models,
  inherited,
  group = "all",
}: {
  idPrefix: string;
  value: AgentSettingsForm;
  onChange: (next: AgentSettingsForm) => void;
  models: ModelRow[];
  /** the values in force when a field is left empty (a project's page) */
  inherited?: Partial<Record<keyof AgentSettingsForm, number | string | null>>;
  group?: "all" | "collaboration" | "resources";
}) {
  const global = useAgentSettings();
  const copy = useSettingsCopy();
  const inheritedMode = inherited ? global.data?.commandCgroupMode : "auto";
  const set = <K extends keyof AgentSettingsForm>(key: K, v: string) => onChange({ ...value, [key]: v });
  const placeholder = (key: keyof AgentSettingsForm) => {
    const v = inherited ? global.data?.[key] ?? inherited[key] : undefined;
    return v === null || v === undefined ? undefined : `${s.inherit} ${v}`;
  };
  const source = (key: keyof AgentSettingsForm) => inherited ? (
    <div className="flex items-center gap-2 text-xs">
      <span className="text-muted-foreground">{value[key] ? copy.overridden : copy.inherited}</span>
      {value[key] ? <Button size="sm" variant="ghost" className="h-6 px-1 text-xs" onClick={() => set(key, "")}>{copy.restore}</Button> : null}
    </div>
  ) : null;
  const number = (key: "maxDepth" | "maxChildren" | "idleMinutes" | "modelRetries" | "commandOomPriority" | "memoryFloorPercent" | "commandMemoryLimitPercent" | "commandSwapLimitMb", label: string, hint?: string, min = 1, max?: number) => (
    <div className="flex flex-col gap-1.5">
      <Label htmlFor={`${idPrefix}-${key}`}>{label}</Label>
      <Input id={`${idPrefix}-${key}`} type="number" min={min} max={max} inputMode="numeric" value={value[key]} placeholder={placeholder(key)} onChange={(e) => set(key, e.target.value)} className="w-40" />
      {source(key)}
      {hint ? <span className="text-muted-foreground text-xs">{hint}</span> : null}
    </div>
  );
  const modelPick = (key: "childModel", effortKey: "childEffort", label: string, hint: string) => {
    const slug = value[key] || inherited?.[key] || "";
    const chosen = models.find((m) => m.slug === slug);
    const levels = chosen?.reasoningLevels ?? [];
    return (
      <div className="flex flex-col gap-1.5">
        <Label htmlFor={`${idPrefix}-${key}`}>{label}</Label>
        <div className="flex flex-wrap gap-2">
          <Select value={value[key] || NONE} onValueChange={(v) => onChange({ ...value, [key]: v === NONE ? "" : v, [effortKey]: "" })}>
            <SelectTrigger id={`${idPrefix}-${key}`} className="w-56" aria-label={label}>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value={NONE}>{inherited && inherited[key] ? `${s.inherit} ${inherited[key]}` : s.sameAsThread}</SelectItem>
              {models.filter((m) => m.slug).map((m) => (
                <SelectItem key={m.id} value={m.slug!} className="font-mono">{m.slug}</SelectItem>
              ))}
            </SelectContent>
          </Select>
          {levels.length > 0 ? (
            <Select value={value[effortKey] || NONE} onValueChange={(v) => set(effortKey, v === NONE ? "" : v)}>
              <SelectTrigger className="w-40" aria-label={t.levelFor(label)}>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={NONE}>{s.effortAuto}</SelectItem>
                {levels.map((l) => (
                  <SelectItem key={l} value={l} className="font-mono">{l}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          ) : null}
        </div>
        <span className="text-muted-foreground text-xs">{hint}</span>
        {source(key)}
      </div>
    );
  };
  return (
    <div className="grid gap-4 sm:grid-cols-2">
      {inherited ? <p className="text-muted-foreground text-xs sm:col-span-2">{copy.inheritanceHint}</p> : null}
      {group !== "resources" ? <>
      {number("maxDepth", s.maxDepth, s.maxDepthHint)}
      {number("maxChildren", s.maxChildren)}
      {modelPick("childModel", "childEffort", s.childModel, s.childModelHint)}
      <details className="sm:col-span-2 rounded-md border p-3">
        <summary className="cursor-pointer text-sm">{copy.advanced}</summary>
        <div className="mt-3 grid gap-4 sm:grid-cols-2">
          {number("idleMinutes", s.idleMinutes, s.idleMinutesHint)}
          {number("modelRetries", s.modelRetries, s.modelRetriesHint)}
        </div>
      </details>
      </> : null}
      {group !== "collaboration" ? <>
      <div className="flex flex-col gap-1.5">
        <Label htmlFor={`${idPrefix}-commandCgroupMode`}>{s.commandCgroupMode}</Label>
        <Select value={value.commandCgroupMode || NONE} onValueChange={(v) => set("commandCgroupMode", v === NONE ? "" : v)}>
          <SelectTrigger id={`${idPrefix}-commandCgroupMode`} className="w-56" aria-label={s.commandCgroupMode}>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value={NONE}>{inheritedMode ? `${s.inherit} ${inheritedMode}` : s.inherit}</SelectItem>
            <SelectItem value="auto">{s.cgroupAuto}</SelectItem>
            <SelectItem value="off">{s.cgroupOff}</SelectItem>
            <SelectItem value="required">{s.cgroupRequired}</SelectItem>
          </SelectContent>
        </Select>
        <span className="text-muted-foreground text-xs">{s.commandCgroupModeHint}</span>
        {source("commandCgroupMode")}
      </div>
      {number("commandMemoryLimitPercent", s.commandMemoryLimitPercent, s.commandMemoryLimitPercentHint, 1, 80)}
      {number("commandSwapLimitMb", s.commandSwapLimitMb, s.commandSwapLimitMbHint, 0, 65536)}
      <details className="sm:col-span-2 rounded-md border p-3">
        <summary className="cursor-pointer text-sm">{copy.advanced}</summary>
        <div className="mt-3 grid gap-4 sm:grid-cols-2">
          {number("memoryFloorPercent", s.memoryFloorPercent, s.memoryFloorPercentHint, 0)}
          {number("commandOomPriority", s.commandOomPriority, s.commandOomPriorityHint, 0)}
        </div>
      </details>
      </> : null}
    </div>
  );
}
