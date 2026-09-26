import type { RouteObject } from "react-router";
import { ThreadPage } from "./chat/ThreadPage";
import { ProjectWindow } from "./frame/ProjectWindow";
import { NotFoundPage } from "./pages/Placeholder";
import { WelcomePage } from "./pages/WelcomePage";
import { Shell } from "./shell/Shell";

// Phoenix serves the shell for every path (LongxWeb.PageController); the
// client router owns what happens next. Shape follows an IDE: a welcome
// screen, one wizard to open/create, a project window with the chat in the
// middle and tool windows around it, and settings.
//
// The settings pages and the wizard load when first visited (`lazy`): every
// page loads the entry before anything shows, and on a weak network each
// megabyte of it is seconds — the conversation is what opens first.
const settings = async () => ({ Component: (await import("./pages/SettingsPage")).SettingsPage });

export const routes: RouteObject[] = [
  {
    element: <Shell />,
    children: [
      { path: "/", element: <WelcomePage /> },
      { path: "/new", lazy: async () => ({ Component: (await import("./pages/ProjectWizard")).ProjectWizard }) },
      {
        path: "/p/:slug",
        element: <ProjectWindow />,
        children: [
          { index: true, element: <ThreadPage /> },
          { path: "settings", lazy: async () => ({ Component: (await import("./pages/ProjectSettingsPage")).ProjectSettingsPage }) },
          { path: "t/:threadId", element: <ThreadPage /> },
        ],
      },
      { path: "/settings", lazy: settings },
      { path: "/settings/:section", lazy: settings },
      { path: "*", element: <NotFoundPage /> },
    ],
  },
];
