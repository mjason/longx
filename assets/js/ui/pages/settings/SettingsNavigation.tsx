import { useState } from "react";
import { Link, useNavigate } from "react-router";
import { t } from "@/ui/strings";
import { useSettingsCopy } from "./copy";
import { useViewport } from "@/core/viewport";

export const GLOBAL_GROUPS = [
  { key: "models", sections: ["models", "providers", "browsers", "connections", "credentials"] },
  { key: "agent", sections: ["agent", "resources", "watches"] },
  { key: "workspace", sections: ["knowledge", "files"] },
  { key: "application", sections: ["appearance", "keys", "https", "update"] },
  { key: "diagnostics", sections: ["diagnostics", "dependencies", "processes", "requests"] },
] as const;
export const PROJECT_GROUPS = [
  { key: "project", sections: ["project"] },
  { key: "agent", sections: ["agent", "resources", "watches"] },
  { key: "workspace", sections: ["extensions", "files"] },
] as const;
export const PROJECT_SECTIONS: readonly string[] = PROJECT_GROUPS.flatMap((group) => [...group.sections]);
export const GLOBAL_SECTIONS: readonly string[] = GLOBAL_GROUPS.flatMap((group) => [...group.sections]);

export function useSettingsLabel() {
  const s = useSettingsCopy();
  return (key: string) => ({
    project: s.projectGeneral, extensions: s.extensions, resources: s.resources,
    connections: s.connections, diagnostics: s.diagnostics,
  }[key] ?? t.settingsSections[key] ?? key);
}

export function SettingsNavigation({ project = false, compact = false, active, href }: { project?: boolean; compact?: boolean; active: string; href: (section: string) => string }) {
  const s = useSettingsCopy();
  const label = useSettingsLabel();
  const [query, setQuery] = useState("");
  const viewport = useViewport();
  const navigate = useNavigate();
  const groups = project ? PROJECT_GROUPS : GLOBAL_GROUPS;
  if ((project || compact) && viewport === "phone") {
    return <select aria-label={s.center} className="border-input bg-background w-full rounded-md border p-2 text-sm"
      value={active} onChange={(event) => navigate(href(event.target.value))}>
      {groups.map((group) => <optgroup key={group.key} label={s.groups[group.key]}>
        {group.sections.map((section) => <option key={section} value={section}>{label(section)}</option>)}
      </optgroup>)}
    </select>;
  }
  return (
    <nav aria-label={s.center} className="space-y-4">
      <input aria-label={s.search} placeholder={s.search} value={query} onChange={(e) => setQuery(e.target.value)}
        className="border-input bg-background w-full rounded-md border px-3 py-2 text-xs" />
      {groups.map((group) => {
        const sections = group.sections.filter((section) => label(section).toLowerCase().includes(query.toLowerCase()));
        return sections.length ? <div key={group.key}>
          <p className="text-muted-foreground px-3 pb-1 text-xs">{s.groups[group.key]}</p>
          {sections.map((section) => <Link key={section} to={href(section)} aria-current={section === active ? "page" : undefined}
            className={`flex items-center justify-between gap-2 rounded-md px-3 py-2 text-sm ${section === active ? "bg-accent font-medium" : "hover:bg-accent/40"}`}>
            <span className="min-w-0">{label(section)}</span>
          </Link>)}
        </div> : null;
      })}
    </nav>
  );
}
