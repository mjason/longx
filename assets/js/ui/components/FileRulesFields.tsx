// The two texts of a file-rules layer — what to ignore, what to watch even when
// .gitignore hides it — shared by Settings → 文件监控 and a project's settings.
import type { FileRules } from "@/core/fileRules";
import { Label } from "@/ui/components/ui/label";
import { Textarea } from "@/ui/components/ui/textarea";
import { t } from "@/ui/strings";

const s = t.fileRules;

export function FileRulesFields({ idPrefix, value, onChange, builtin }: { idPrefix: string; value: FileRules; onChange: (v: FileRules) => void; builtin?: { ignore: string[]; watch: string[] } }) {
  return (
    <div className="grid gap-4 md:grid-cols-2">
      {(["ignore", "watch"] as const).map((k) => (
        <div key={k} className="min-w-0 space-y-2">
          <Label htmlFor={`${idPrefix}-${k}`}>{s[k]}</Label>
          <Textarea
            id={`${idPrefix}-${k}`}
            rows={5}
            value={value[k]}
            placeholder={s.placeholder[k]}
            onChange={(e) => onChange({ ...value, [k]: e.target.value })}
            className="font-mono text-xs"
            spellCheck={false}
            autoCapitalize="none"
          />
          <p className="text-muted-foreground text-xs">{s.hints[k]}</p>
          {builtin ? (
            <p className="text-muted-foreground text-xs">
              {s.builtin}
              <span className="font-mono break-words">{builtin[k].join("  ")}</span>
            </p>
          ) : null}
        </div>
      ))}
    </div>
  );
}
