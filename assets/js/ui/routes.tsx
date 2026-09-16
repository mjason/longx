import type { RouteObject } from "react-router";
import { ThreadPage } from "./chat/ThreadPage";
import { ProjectWindow } from "./frame/ProjectWindow";
import { NotFoundPage } from "./pages/Placeholder";
import { ProjectSettingsPage } from "./pages/ProjectSettingsPage";
import { ProjectWizard } from "./pages/ProjectWizard";
import { SettingsPage } from "./pages/SettingsPage";
import { WelcomePage } from "./pages/WelcomePage";
import { EmbedPage } from "./pages/EmbedPage";
import { Shell } from "./shell/Shell";

// Phoenix serves the shell for every path (LongxWeb.PageController); the
// client router owns what happens next. Shape follows an IDE: a welcome
// screen, one wizard to open/create, a project window with the chat in the
// middle and tool windows around it, and settings.
export const routes: RouteObject[] = [
  // the phone app's WebView pieces: outside the shell, no frame
  { path: "/embed/editor/:projectId", element: <EmbedPage kind="editor" /> },
  { path: "/embed/diff/:projectId", element: <EmbedPage kind="diff" /> },
  {
    element: <Shell />,
    children: [
      { path: "/", element: <WelcomePage /> },
      { path: "/new", element: <ProjectWizard /> },
      {
        path: "/p/:slug",
        element: <ProjectWindow />,
        children: [
          { index: true, element: <ThreadPage /> },
          { path: "settings", element: <ProjectSettingsPage /> },
          { path: "t/:threadId", element: <ThreadPage /> },
        ],
      },
      { path: "/settings", element: <SettingsPage /> },
      { path: "/settings/:section", element: <SettingsPage /> },
      { path: "*", element: <NotFoundPage /> },
    ],
  },
];
