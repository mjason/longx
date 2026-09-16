// The composer's rail — the access mode on the left, the model (with its
// reasoning level) on the right — as bottom sheets, the phone's answer to
// the web's popovers. Reads and writes useCodexRuntime's state through the
// chat context.
import { ChevronDown, Globe, ShieldAlert, ShieldCheck, ShieldOff } from "lucide-react-native";
import { useState } from "react";
import { Pressable, Switch, Text, View } from "react-native";
import { Icon } from "@/components/ui/icon";
import { PickSheet, Sheet } from "@/components/Sheet";
import { useModels } from "@/core/projects";
import type { AccessMode } from "@/core/chat/adapter";
import { t } from "@/lib/strings";
import { useChat } from "./ChatContext";

const s = t.thread;

export function ComposerLeading() {
  const { mode, setMode, state, thread } = useChat();
  const [open, setOpen] = useState(false);
  const shield = mode.sandbox === "danger_full_access" ? ShieldOff : mode.sandbox === "read_only" ? ShieldCheck : ShieldAlert;
  const full = mode.sandbox === "danger_full_access";
  return (
    <View className="flex-row items-center gap-2">
      <Pressable onPress={() => setOpen(true)} className="active:bg-accent flex-row items-center gap-1 rounded-md px-1.5 py-1" accessibilityLabel={s.mode} testID="mode-picker">
        <Icon as={shield} className={`size-4 ${full ? "text-destructive" : "text-muted-foreground"}`} />
        {mode.networkAccess && mode.sandbox === "workspace_write" ? <Icon as={Globe} className="text-muted-foreground size-3" /> : null}
        {mode.approvalPolicy === "auto_accept" ? <Text className="text-destructive text-[10px]">{s.approvalOptions["auto_accept"]}</Text> : null}
      </Pressable>
      {state === "running" ? (
        <Text className="text-muted-foreground text-xs">{s.running}</Text>
      ) : state === "approval" ? (
        <Text className="text-warning text-xs">{s.awaitingApproval}</Text>
      ) : null}
      <ModeSheet open={open} onClose={() => setOpen(false)} mode={mode} onChange={setMode} started={thread !== undefined} />
    </View>
  );
}

function ModeSheet({ open, onClose, mode, onChange, started }: { open: boolean; onClose: () => void; mode: AccessMode; onChange: (m: AccessMode) => void; started: boolean }) {
  return (
    <Sheet open={open} onClose={onClose} title={s.mode}>
      <View className="gap-4 px-6 pb-2">
        <Group label={s.sandbox}>
          {(["read_only", "workspace_write", "danger_full_access"] as const).map((v) => (
            <Choice key={v} label={s.sandboxOptions[v]!} selected={mode.sandbox === v} danger={v === "danger_full_access"} onPress={() => onChange({ ...mode, sandbox: v })} />
          ))}
        </Group>
        <Group label={s.approval}>
          {(["on_request", "auto_accept", "untrusted", "never"] as const).map((v) => (
            <Choice key={v} label={s.approvalOptions[v]!} selected={mode.approvalPolicy === v} danger={v === "auto_accept"} onPress={() => onChange({ ...mode, approvalPolicy: v })} />
          ))}
        </Group>
        <Toggle label={s.network} value={mode.networkAccess} onChange={(v) => onChange({ ...mode, networkAccess: v })} disabled={mode.sandbox !== "workspace_write"} />
        <Toggle label={s.webSearch} hint={started ? s.newChatOnly : undefined} value={mode.webSearch} onChange={(v) => onChange({ ...mode, webSearch: v })} disabled={started} />
        <Toggle label={s.multiAgent} hint={started ? s.newChatOnly : undefined} value={mode.multiAgent} onChange={(v) => onChange({ ...mode, multiAgent: v })} disabled={started} />
        <Toggle label={s.autoReview} hint={started ? s.newChatOnly : undefined} value={mode.autoReview} onChange={(v) => onChange({ ...mode, autoReview: v })} disabled={started || mode.approvalPolicy === "auto_accept"} />
      </View>
    </Sheet>
  );
}

function Group({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <View className="gap-1">
      <Text className="text-muted-foreground text-xs font-medium">{label}</Text>
      {children}
    </View>
  );
}

function Choice({ label, selected, danger, onPress }: { label: string; selected: boolean; danger?: boolean; onPress: () => void }) {
  return (
    <Pressable onPress={onPress} className="min-h-11 flex-row items-center gap-3 py-1" accessibilityRole="radio" accessibilityState={{ selected }}>
      <View className={`size-5 items-center justify-center rounded-full border-2 ${selected ? "border-primary" : "border-muted-foreground/50"}`}>
        {selected ? <View className="bg-primary size-2.5 rounded-full" /> : null}
      </View>
      <Text className={`text-base ${danger ? "text-destructive" : "text-foreground"}`}>{label}</Text>
    </Pressable>
  );
}

function Toggle({ label, hint, value, onChange, disabled }: { label: string; hint?: string; value: boolean; onChange: (v: boolean) => void; disabled?: boolean }) {
  return (
    <View className="min-h-11 flex-row items-center gap-3">
      <View className="flex-1">
        <Text className={`text-base ${disabled ? "text-muted-foreground" : "text-foreground"}`}>{label}</Text>
        {hint ? <Text className="text-muted-foreground text-xs">{hint}</Text> : null}
      </View>
      <Switch value={value} onValueChange={onChange} disabled={disabled} />
    </View>
  );
}

export function ComposerTrailing() {
  const { thread, model, setModel, effort, setEffort, defaultModelId } = useChat();
  const models = useModels();
  const rows = (models.data ?? []).filter((m) => m.slug);
  const [open, setOpen] = useState<"model" | "effort" | null>(null);
  const current = thread
    ? (thread.modelSlug ?? rows.find((m) => m.default)?.slug ?? null)
    : (defaultModelId && rows.find((m) => m.id === defaultModelId)?.slug) || rows.find((m) => m.default)?.slug || null;
  const selected = model ?? current;
  const row = rows.find((m) => m.slug === selected);
  const inForce = (thread && (model === null || model === thread.modelSlug) ? thread.reasoningEffort : null) ?? row?.reasoningEffort ?? null;
  const shownEffort = effort ?? inForce;
  const byProvider = new Map<string, typeof rows>();
  for (const m of rows) byProvider.set(providerName(m), [...(byProvider.get(providerName(m)) ?? []), m]);

  return (
    <View className="flex-row items-center">
      <Pressable onPress={() => setOpen("model")} className="active:bg-accent max-w-[42vw] flex-row items-center gap-1 rounded-md px-2 py-1" accessibilityLabel={s.model} testID="model-picker">
        <Text className="text-foreground font-mono text-xs" numberOfLines={1}>
          {row ? row.slug : s.defaultModel}
        </Text>
        {shownEffort ? <Text className="text-muted-foreground text-xs">{s.effortLevels[shownEffort] ?? shownEffort}</Text> : null}
        <Icon as={ChevronDown} className="text-muted-foreground size-3" />
      </Pressable>
      <PickSheet
        open={open === "model"}
        onClose={() => setOpen(null)}
        title={s.model}
        sections={[...byProvider.entries()].map(([name, group]) => ({
          label: name,
          options: group.map((m) => ({ id: m.slug!, label: m.slug!, detail: `${name} · ${formatWindow(m.contextWindow)}` })),
        }))}
        selected={selected}
        onPick={(slug) => {
          setModel(slug === current ? null : slug);
          const picked = rows.find((m) => m.slug === slug);
          if (picked && picked.reasoningLevels.length > 0) setTimeout(() => setOpen("effort"), 350);
        }}
      />
      <PickSheet
        open={open === "effort"}
        onClose={() => setOpen(null)}
        title={s.reasoning}
        sections={[{ options: (row?.reasoningLevels ?? []).map((l) => ({ id: l, label: s.effortLevels[l] ?? l })) }]}
        selected={shownEffort}
        onPick={(level) => setEffort(level)}
      />
    </View>
  );
}

function providerName(m: { provider?: { name?: string | null } | null }): string {
  return m.provider?.name ?? "";
}

function formatWindow(tokens: number | null | undefined): string {
  if (!tokens) return "";
  return tokens >= 1_000_000 ? `${Math.round(tokens / 100_000) / 10}M` : `${Math.round(tokens / 1000)}k`;
}
