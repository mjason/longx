// The native kernel's team parameters as form fields — the global page and
// a project's overrides share them (a project leaves a field empty to inherit).
import type { ModelRow } from "@/core/ai";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/ui/components/ui/select";
import { t } from "@/ui/strings";

const s = t.agentKernel;

/** Every value as the form holds it: a string ("" = inherit / unset). */
export type AgentSettingsForm = {
  maxDepth: string;
  maxChildren: string;
  idleMinutes: string;
  modelRetries: string;
  childModel: string;
  childEffort: string;
};

export const emptyAgentSettingsForm: AgentSettingsForm = {
  maxDepth: "",
  maxChildren: "",
  idleMinutes: "",
  modelRetries: "",
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
}: {
  idPrefix: string;
  value: AgentSettingsForm;
  onChange: (next: AgentSettingsForm) => void;
  models: ModelRow[];
  /** the values in force when a field is left empty (a project's page) */
  inherited?: Partial<Record<keyof AgentSettingsForm, number | string | null>>;
}) {
  const set = <K extends keyof AgentSettingsForm>(key: K, v: string) => onChange({ ...value, [key]: v });
  const placeholder = (key: keyof AgentSettingsForm) => {
    const v = inherited?.[key];
    return v === null || v === undefined ? undefined : `${s.inherit} ${v}`;
  };
  const number = (key: "maxDepth" | "maxChildren" | "idleMinutes" | "modelRetries", label: string, hint?: string) => (
    <div className="flex flex-col gap-1.5">
      <Label htmlFor={`${idPrefix}-${key}`}>{label}</Label>
      <Input id={`${idPrefix}-${key}`} type="number" min={1} inputMode="numeric" value={value[key]} placeholder={placeholder(key)} onChange={(e) => set(key, e.target.value)} className="w-40" />
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
              <SelectTrigger className="w-40" aria-label={`${label} 档位`}>
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
      </div>
    );
  };
  return (
    <div className="grid gap-4 sm:grid-cols-2">
      {number("maxDepth", s.maxDepth, s.maxDepthHint)}
      {number("maxChildren", s.maxChildren)}
      {number("idleMinutes", s.idleMinutes, s.idleMinutesHint)}
      {number("modelRetries", s.modelRetries, s.modelRetriesHint)}
      {modelPick("childModel", "childEffort", s.childModel, s.childModelHint)}
    </div>
  );
}
