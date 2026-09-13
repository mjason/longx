import type { RouteObject } from "react-router";
import { ProjectWindow } from "./frame/ProjectWindow";
import { ChatPlaceholder } from "./pages/ChatPlaceholder";
import { NotFoundPage } from "./pages/Placeholder";
import { ProjectWizard } from "./pages/ProjectWizard";
import { SettingsPage } from "./pages/SettingsPage";
import { WelcomePage } from "./pages/WelcomePage";
import { Shell } from "./shell/Shell";

// Phoenix serves the shell for every path (LongxWeb.PageController); the
// client router owns what happens next. Shape follows an IDE: a welcome
// screen, one wizard to open/create, a project window with the chat in the
// middle and tool windows around it, and settings.
export const routes: RouteObject[] = [
  {
    element: <Shell />,
    children: [
      { path: "/", element: <WelcomePage /> },
      { path: "/new", element: <ProjectWizard /> },
      {
        path: "/p/:slug",
        element: <ProjectWindow />,
        children: [
          { index: true, element: <ChatPlaceholder /> },
          { path: "settings", element: <ChatPlaceholder /> },
          { path: "t/:threadId", element: <ChatPlaceholder /> },
        ],
      },
      { path: "/settings", element: <SettingsPage /> },
      { path: "/settings/:section", element: <SettingsPage /> },
      { path: "*", element: <NotFoundPage /> },
    ],
  },
];
