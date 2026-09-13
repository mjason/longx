import { Monitor, Moon, Sun } from "lucide-react";
import { nextTheme, useTheme } from "@/core/theme";
import { t } from "@/ui/strings";

/** One tap cycles dark → light → system; the icon shows the current choice. */
export function ThemeToggle() {
  const { preference, setTheme } = useTheme();
  const Icon = preference === "dark" ? Moon : preference === "light" ? Sun : Monitor;
  return (
    <button
      type="button"
      aria-label={`${t.theme}：${t.themes[preference]}`}
      title={t.themes[preference]}
      onClick={() => setTheme(nextTheme(preference))}
      className="touch-target text-muted-foreground hover:text-foreground flex items-center justify-center rounded-md"
      data-testid="theme-toggle"
    >
      <Icon className="size-5" />
    </button>
  );
}
