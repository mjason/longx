import { useTranslation } from "react-i18next";
import { ChevronRight } from "lucide-react";
import { useEffect } from "react";
import { Link, useNavigate, useParams } from "react-router";
import { useViewport } from "@/core/viewport";
import { Page, TopBar } from "@/ui/shell/Shell";
import { t } from "@/ui/strings";
import { ModelsSection } from "./settings/ModelsSection";
import { ProvidersSection } from "./settings/ProvidersSection";
import { KnowledgeSection } from "./settings/KnowledgeSection";
import { AgentKernelSection, AgentConnectionsSection } from "./settings/AgentKernelSection";
import { SettingsNavigation, GLOBAL_GROUPS, useSettingsLabel } from "./settings/SettingsNavigation";
import { SettingsDraftProvider } from "./settings/SettingsDraft";
import { useSettingsCopy } from "./settings/copy";
import { CommandGuardStatus } from "@/ui/components/CommandGuardStatus";
import { DependenciesSection } from "./settings/DependenciesSection";
import { CredentialsSection } from "./settings/CredentialsSection";
import { RequestsSection } from "./settings/RequestsSection";
import { UpdateSection } from "./settings/UpdateSection";
import { WatchesSection } from "./settings/WatchesSection";
import { ProcessesSection } from "./settings/ProcessesSection";
import { BrowsersSection } from "./settings/BrowsersSection";
import { HttpsSection } from "./settings/HttpsSection";
import { FileRulesSection } from "./settings/FileRulesSection";
import { AppearanceSection } from "./settings/AppearanceSection";
import { KeysSection } from "./settings/KeysSection";

const SECTIONS = GLOBAL_GROUPS.flatMap((group) => [...group.sections]);
type Section = (typeof SECTIONS)[number];

/**
 * IDEA's Preferences: categories on the left, content on the right. On a
 * phone it is the iOS pattern — a list, then a sub page.
 */
export function SettingsPage() {
  return <SettingsDraftProvider><SettingsPageBody /></SettingsDraftProvider>;
}

function SettingsPageBody() {
    useTranslation();
  const { section } = useParams<{ section?: Section }>();
  const viewport = useViewport();
  const navigate = useNavigate();
  const label = useSettingsLabel();
  const current: Section | undefined = section && SECTIONS.includes(section) ? section : undefined;

  // a desktop without a section opens the first one — from an effect: React
  // Router drops a navigate() issued before the page has mounted, and one
  // queued from the render (a microtask) once lost that race whenever the
  // lazily loaded page committed late (CI's runner), leaving /settings as it was
  useEffect(() => {
    if (viewport !== "phone" && !current) navigate("/settings/models", { replace: true });
  }, [viewport, current, navigate]);

  if (viewport === "phone") {
    if (!current) return <SectionList />;
    return (
      <>
        <TopBar title={label(current)} back="/settings" />
        <Page><SectionBody section={current} /></Page>
      </>
    );
  }

  const active = current ?? "models";

  return (
    <>
      <TopBar title={t.settings} back="/" />
      <Page className="grid grid-cols-[220px_minmax(0,1fr)] gap-6">
        <SettingsNavigation active={active} href={(section) => `/settings/${section}`} />
        <section className="min-w-0"><SectionBody section={active} /></section>
      </Page>
    </>
  );
}

function SectionList() {
    useTranslation();
  const label = useSettingsLabel();
  return (
    <>
      <TopBar title={t.settings} back="/" />
      <Page>
        <ul className="divide-y rounded-lg border">
          {SECTIONS.map((s) => (
            <li key={s}>
              <Link to={`/settings/${s}`} className="hover:bg-accent/40 flex items-center justify-between px-4 py-3">
                {label(s)} <ChevronRight className="text-muted-foreground size-4" />
              </Link>
            </li>
          ))}
        </ul>
      </Page>
    </>
  );
}

export function SectionBody({ section }: { section: string }) {
  switch (section) {
    case "models":
      return <ModelsSection />;
    case "providers":
      return <ProvidersSection />;
    case "dependencies":
      return <DependenciesSection />;
    case "knowledge":
      return <KnowledgeSection />;
    case "agent":
      return <AgentKernelSection group="collaboration" />;
    case "resources":
      return <AgentKernelSection group="resources" />;
    case "connections":
      return <AgentConnectionsSection />;
    case "diagnostics":
      return <DiagnosticsSection />;
    case "files":
      return <FileRulesSection />;
    case "credentials":
      return <CredentialsSection />;
    case "update":
      return <UpdateSection />;
    case "requests":
      return <RequestsSection />;
    case "watches":
      return <WatchesSection />;
    case "processes":
      return <ProcessesSection />;
    case "browsers":
      return <BrowsersSection />;
    case "https":
      return <HttpsSection />;
    case "keys":
      return <KeysSection />;
    case "appearance":
      return <AppearanceSection />;
  }
}

export function DiagnosticsSection({ projectId }: { projectId?: string }) {
  const s = useSettingsCopy();
  return <div className="space-y-4" data-testid="section-diagnostics"><p className="text-muted-foreground text-xs">{s.machineScope}</p><CommandGuardStatus projectId={projectId} /></div>;
}

