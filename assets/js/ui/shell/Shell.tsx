import { ChevronLeft } from "lucide-react";
import { useEffect, type ReactNode } from "react";
import { Link, Outlet } from "react-router";
import { applyTheme } from "@/core/theme";
import { useViewport } from "@/core/viewport";
import { CommandPalette } from "@/ui/components/CommandPalette";
import { Toaster } from "@/ui/components/ui/sonner";
import { TooltipProvider } from "@/ui/components/ui/tooltip";
import { ConnectionBanner } from "./ConnectionBanner";
import { SandboxBanner } from "./SandboxBanner";

/**
 * Mobile-first frame: one column, a thin top bar that respects the notch,
 * banners under it, the page below. Desktop only widens the column.
 */
export function Shell() {
  const viewport = useViewport();
  useEffect(() => applyTheme(), []);
  return (
    <TooltipProvider delayDuration={300}>
      <div className="min-h-dvh flex flex-col">
        <ConnectionBanner />
        <SandboxBanner />
        <Outlet />
      </div>
      <Toaster />
      {viewport === "desktop" ? <CommandPalette /> : null}
    </TooltipProvider>
  );
}

export function TopBar({
  title,
  back,
  actions,
  wide = false,
}: {
  title: ReactNode;
  back?: string;
  actions?: ReactNode;
  /** full width (the IDE window); pages are centred at a readable width */
  wide?: boolean;
}) {
  // the IDE window's bar belongs to its frame; a page's bar sits on the page
  const surface = wide ? "bg-sidebar border-sidebar-border" : "bg-background";
  return (
    <header className={`safe-top ${surface} sticky top-0 z-20 border-b`}>
      <div className={`safe-x mx-auto flex h-14 w-full items-center gap-2 ${wide ? "" : "max-w-5xl"}`}>
        {back ? (
          <Link to={back} aria-label="返回" className="touch-target -ml-2 flex items-center justify-center rounded-md">
            <ChevronLeft className="size-6" />
          </Link>
        ) : null}
        <h1 className="min-w-0 flex-1 truncate text-base font-semibold">{title}</h1>
        {actions}
      </div>
    </header>
  );
}

/** Page body with the side gutters and room for a bottom action bar. */
export function Page({ children, className = "" }: { children: ReactNode; className?: string }) {
  return (
    <main className={`safe-x mx-auto w-full max-w-5xl flex-1 pb-24 pt-4 ${className}`}>{children}</main>
  );
}

/**
 * Primary action pinned to the bottom of the viewport on every screen size
 * (a dialog footer): it must never depend on the page scrolling to be seen.
 * Long content scrolls in its own box (see DirectoryPicker) or under it.
 */
export function BottomBar({ children }: { children: ReactNode }) {
  return (
    <div className="safe-bottom bg-background fixed inset-x-0 bottom-0 z-20 border-t" data-testid="bottom-bar">
      <div className="safe-x mx-auto flex w-full max-w-5xl gap-2 py-3">{children}</div>
    </div>
  );
}
