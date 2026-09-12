import type { RouteObject } from "react-router";
import { NewProjectPage } from "./pages/NewProjectPage";
import { NotFoundPage, ThreadPage } from "./pages/Placeholder";
import { ProjectPage } from "./pages/ProjectPage";
import { ProjectsPage } from "./pages/ProjectsPage";
import { Shell } from "./shell/Shell";

// Phoenix serves the shell for every path (LongxWeb.PageController); the
// client router owns what happens next.
export const routes: RouteObject[] = [
  {
    element: <Shell />,
    children: [
      { path: "/", element: <ProjectsPage /> },
      { path: "/new", element: <NewProjectPage /> },
      { path: "/p/:slug", element: <ProjectPage /> },
      { path: "/p/:slug/settings", element: <ProjectPage /> },
      { path: "/p/:slug/t/:threadId", element: <ThreadPage /> },
      { path: "/settings", element: <NotFoundPage /> },
      { path: "*", element: <NotFoundPage /> },
    ],
  },
];
