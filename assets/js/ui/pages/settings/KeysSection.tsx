// Settings → 快捷键: every command with the keys that run it, on this device.
// 添加 listens for a new key — a chord (⌘/Ctrl/Alt with a key), or a
// space-menu sequence (space first, Enter to end); Esc cancels — and checks
// it (an input method's key or another command's is refused, one a browser
// tab keeps is the installed app's). A key comes off with its ×; 恢复默认
// gives the command its shipped keys back. Kept in localStorage
// (core/keys/overrides), read by the dispatcher at once.
import { X } from "lucide-react";
import { useEffect, useState } from "react";
import { commandGroup, type Binding } from "@/core/keys/bindings";
import { COMMANDS, GROUPS } from "@/core/keys/commands";
import { eventChord, formatKeys, isMacPlatform } from "@/core/keys/notation";
import { loadOverrides, resetAllKeys, setCommandKeys, useBindings, validateKeys } from "@/core/keys/overrides";
import { Button } from "@/ui/components/ui/button";
import { Input } from "@/ui/components/ui/input";
import { appWindow, updateKeysUi } from "@/ui/keys/state";
import { t } from "@/ui/strings";

const s = t.keys;

type Recording = { command: string; sequence: string[] | null };

export function KeysSection() {
  const bindings = useBindings();
  const mac = isMacPlatform();
  const app = appWindow();
  const [query, setQuery] = useState("");
  const [recording, setRecording] = useState<Recording | null>(null);
  const [error, setError] = useState<{ command: string; reason: string } | null>(null);
  const overrides = loadOverrides();

  // the command's keys as stored, this platform's only
  const keysOf = (command: string) => bindings.filter((b) => b.command === command && (b.when?.mac === undefined || b.when.mac === mac));

  function save(command: string, keys: string) {
    const check = validateKeys(keys, command, bindings, mac);
    if (!check.ok) return setError({ command, reason: check.reason });
    setError(null);
    setCommandKeys(command, [...keysOf(command).map((b) => b.keys), keys]);
  }

  useEffect(() => {
    if (!recording) return;
    updateKeysUi({ recording: true });
    const onKey = (e: KeyboardEvent) => {
      e.preventDefault();
      e.stopPropagation();
      const { command, sequence } = recording;
      if (sequence) {
        if (e.key === "Enter" && sequence.length > 0) {
          setRecording(null);
          save(command, `SPC ${sequence.join(" ")}`);
        } else if (e.key === "Escape") setRecording(null);
        else if (e.key === "Backspace") setRecording({ command, sequence: sequence.slice(0, -1) });
        else if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) setRecording({ command, sequence: [...sequence, e.key === " " ? "SPC" : e.key] });
        else if (e.key === "Tab") setRecording({ command, sequence: [...sequence, "TAB"] });
        return;
      }
      if (e.key === "Escape") return setRecording(null);
      if (e.key === " " && !e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey) return setRecording({ command, sequence: [] });
      const chord = eventChord(e, mac);
      if (chord === null) return;
      if (!chord.includes("+")) return setError({ command, reason: s.recordingHint });
      setRecording(null);
      save(command, chord);
    };
    window.addEventListener("keydown", onKey, true);
    return () => {
      window.removeEventListener("keydown", onKey, true);
      updateKeysUi({ recording: false });
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [recording]);

  const q = query.trim().toLowerCase();
  const sections = [{ key: "", label: s.common }, ...Object.entries(GROUPS).map(([key, label]) => ({ key, label }))];

  return (
    <div className="grid max-w-3xl gap-4" data-testid="section-keys">
      <p className="text-muted-foreground text-sm">{app ? s.windowApp : s.windowTab}</p>
      <div className="flex items-center gap-2">
        <Input aria-label={s.search} placeholder={s.search} value={query} onChange={(e) => setQuery(e.target.value)} className="h-9 max-w-xs" />
        {Object.keys(overrides).length > 0 ? (
          <Button variant="outline" size="sm" onClick={() => resetAllKeys()}>
            {s.resetAll}
          </Button>
        ) : null}
      </div>
      {sections.map((section) => {
        const ids = Object.keys(COMMANDS).filter((id) => commandGroup(id) === section.key && (q === "" || COMMANDS[id]!.toLowerCase().includes(q) || id.includes(q)));
        if (ids.length === 0) return null;
        return (
          <section key={section.key || "common"} className="grid gap-1">
            <h3 className="text-sm font-medium">
              {section.key ? <kbd className="bg-muted mr-2 rounded px-1.5 py-0.5 font-mono text-xs">SPC {section.key}</kbd> : null}
              {section.label}
            </h3>
            <ul className="divide-y rounded-lg border">
              {ids.map((id) => (
                <CommandRow
                  key={id}
                  id={id}
                  keys={keysOf(id)}
                  mac={mac}
                  changed={overrides[id] !== undefined}
                  recording={recording?.command === id ? recording : null}
                  error={error?.command === id ? error.reason : null}
                  onRecord={() => {
                    setError(null);
                    setRecording({ command: id, sequence: null });
                  }}
                  onRemove={(keys) => setCommandKeys(id, keysOf(id).map((b) => b.keys).filter((k) => k !== keys))}
                  onReset={() => setCommandKeys(id, null)}
                />
              ))}
            </ul>
          </section>
        );
      })}
    </div>
  );
}

function CommandRow({
  id,
  keys,
  mac,
  changed,
  recording,
  error,
  onRecord,
  onRemove,
  onReset,
}: {
  id: string;
  keys: Binding[];
  mac: boolean;
  changed: boolean;
  recording: Recording | null;
  error: string | null;
  onRecord: () => void;
  onRemove: (keys: string) => void;
  onReset: () => void;
}) {
  const title = COMMANDS[id]!;
  return (
    <li className="flex flex-wrap items-center gap-2 px-3 py-2 text-sm" data-testid={`keys-row-${title}`}>
      <span className="min-w-40 flex-1">
        {title}
        {changed ? <span className="text-primary ml-2 text-xs">{s.changed}</span> : null}
      </span>
      <span className="flex flex-wrap items-center gap-1">
        {keys.map((b) => {
          const shown = formatKeys(b.keys, mac);
          return (
            <span key={b.keys} className="bg-muted inline-flex items-center gap-1 rounded px-1.5 py-0.5 font-mono text-xs" {...(b.when?.app ? { "data-app-only": "", title: s.appOnlyHint } : {})}>
              <span>{shown}</span>
              {b.when?.app ? <span className="text-muted-foreground font-sans">{s.appOnly}</span> : null}
              <button type="button" aria-label={s.removeKey(shown)} className="text-muted-foreground hover:text-foreground" onClick={() => onRemove(b.keys)}>
                <X className="size-3" />
              </button>
            </span>
          );
        })}
      </span>
      {recording ? (
        <span className="text-primary text-xs" role="status">
          {recording.sequence ? `SPC ${recording.sequence.join(" ")}` : s.recording}
          <span className="text-muted-foreground ml-2">{s.recordingHint}</span>
        </span>
      ) : (
        <Button variant="ghost" size="sm" onClick={onRecord}>
          {s.record}
        </Button>
      )}
      {changed ? (
        <Button variant="ghost" size="sm" onClick={onReset}>
          {s.reset}
        </Button>
      ) : null}
      {error ? (
        <p className="text-destructive w-full text-xs" role="alert">
          {error}
        </p>
      ) : null}
    </li>
  );
}
