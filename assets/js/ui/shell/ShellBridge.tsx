import { useQueryClient } from "@tanstack/react-query";
import { useEffect } from "react";
import { useLocation, useNavigate } from "react-router";
import { reconnectSocket } from "@/core/socket";
import { useTheme } from "@/core/theme";
import { installShell, setNativeChrome } from "./longxShell";

/**
 * The app's half of the native-shell bridge, inside the router: installs
 * `window.LongxShell` (back / navigate / resume) when a shell is present and
 * reports the page's chrome palette after navigation or a theme change.
 * Renders nothing.
 */
export function ShellBridge() {
  const navigate = useNavigate();
  const location = useLocation();
  const queryClient = useQueryClient();
  const { preference } = useTheme();

  useEffect(
    () =>
      installShell({
        navigate: (path) => navigate(path),
        // back from the background: the socket may be dead, the data stale
        resume: () => {
          reconnectSocket();
          void queryClient.invalidateQueries();
        },
      }),
    [navigate, queryClient],
  );

  // Navigation is only a refresh point: the page reports its current palette;
  // the shell never infers colors from a URL or reads the page's storage.
  useEffect(() => setNativeChrome(preference), [location.pathname, preference]);

  useEffect(() => {
    if (preference !== "system" || typeof window.matchMedia !== "function") return;
    const colorScheme = window.matchMedia("(prefers-color-scheme: dark)");
    const refreshChrome = () => setNativeChrome("system");
    colorScheme.addEventListener("change", refreshChrome);
    return () => colorScheme.removeEventListener("change", refreshChrome);
  }, [preference]);

  return null;
}
