import { useQueryClient } from "@tanstack/react-query";
import { useEffect } from "react";
import { useNavigate } from "react-router";
import { reconnectSocket } from "@/core/socket";
import { useTheme } from "@/core/theme";
import { installShell, readShellTheme, shellPost, shellPresent } from "./longxShell";

/**
 * The app's half of the native-shell bridge, inside the router: installs
 * `window.LongxShell` (back / navigate / resume) when a shell is present and
 * tells it the colours whenever the theme changes. Renders nothing.
 */
export function ShellBridge() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { resolved } = useTheme();

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

  useEffect(() => {
    if (shellPresent()) shellPost({ type: "theme", theme: readShellTheme() });
  }, [resolved]);

  return null;
}
