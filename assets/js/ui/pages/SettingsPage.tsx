import { ChevronRight } from "lucide-react";
import { Link, useNavigate, useParams } from "react-router";
import { useTheme, type ThemePreference } from "@/core/theme";
import { useViewport } from "@/core/viewport";
import { Label } from "@/ui/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/ui/components/ui/select";
import { Page, TopBar } from "@/ui/shell/Shell";
import { t } from "@/ui/strings";
import { ModelsSection } from "./settings/ModelsSection";
import { KnowledgeSection } from "./settings/KnowledgeSection";
import { AgentKernelSection } from "./settings/AgentKernelSection";
import { DependenciesSection } from "./settings/DependenciesSection";
import { RequestsSection } from "./settings/RequestsSection";
import { UpdateSection } from "./settings/UpdateSection";

const SECTIONS = ["models", "dependencies", "knowledge", "agent", "update", "requests", "appearance"] as const;
type Section = (typeof SECTIONS)[number];

/**
 * IDEA's Preferences: categories on the left, content on the right. On a
 * phone it is the iOS pattern — a list, then a sub page.
 */
export function SettingsPage() {
  const { section } = useParams<{ section?: Section }>();
  const viewport = useViewport();
  const navigate = useNavigate();
  const current: Section | undefined = section && SECTIONS.includes(section) ? section : undefined;

  if (viewport === "phone") {
    if (!current) return <SectionList />;
    return (
      <>
        <TopBar title={t.settingsSections[current]!} back="/settings" />
        <Page><SectionBody section={current} /></Page>
      </>
    );
  }

  const active = current ?? "models";
  if (!current) queueMicrotask(() => navigate("/settings/models", { replace: true }));

  return (
    <>
      <TopBar title={t.settings} back="/" />
      <Page className="grid grid-cols-[220px_minmax(0,1fr)] gap-6">
        <nav aria-label={t.settings} className="flex flex-col gap-1">
          {SECTIONS.map((s) => (
            <Link key={s} to={`/settings/${s}`} aria-current={s === active ? "page" : undefined} className={`rounded-md px-3 py-2 text-sm ${s === active ? "bg-accent" : "hover:bg-accent/40"}`}>
              {t.settingsSections[s]}
            </Link>
          ))}
        </nav>
        <section className="min-w-0"><SectionBody section={active} /></section>
      </Page>
    </>
  );
}

function SectionList() {
  return (
    <>
      <TopBar title={t.settings} back="/" />
      <Page>
        <ul className="divide-y rounded-lg border">
          {SECTIONS.map((s) => (
            <li key={s}>
              <Link to={`/settings/${s}`} className="hover:bg-accent/40 flex items-center justify-between px-4 py-3">
                {t.settingsSections[s]} <ChevronRight className="text-muted-foreground size-4" />
              </Link>
            </li>
          ))}
        </ul>
      </Page>
    </>
  );
}

function SectionBody({ section }: { section: Section }) {
  switch (section) {
    case "models":
      return <ModelsSection />;
    case "dependencies":
      return <DependenciesSection />;
    case "knowledge":
      return <KnowledgeSection />;
    case "agent":
      return <AgentKernelSection />;
    case "update":
      return <UpdateSection />;
    case "requests":
      return <RequestsSection />;
    case "appearance":
      return <Appearance />;
  }
}

function Appearance() {
  const { preference, setTheme } = useTheme();
  return (
    <div className="grid max-w-sm gap-2" data-testid="section-appearance">
      <Label>{t.theme}</Label>
      <Select value={preference} onValueChange={(v) => setTheme(v as ThemePreference)}>
        <SelectTrigger className="h-11 w-full" aria-label={t.theme}><SelectValue /></SelectTrigger>
        <SelectContent>
          {(["system", "dark", "light"] as const).map((k) => <SelectItem key={k} value={k}>{t.themes[k]}</SelectItem>)}
        </SelectContent>
      </Select>
    </div>
  );
}
