import { beforeEach, expect, test } from "vitest";
import { project } from "@/ui/test-mocks";
import { quickProjects, orderedProjects, noteProjectVisit } from "./projectNavigation";

beforeEach(() => localStorage.clear());

test("only current, pinned, and active projects stay in the bar, in that order without duplicates", () => {
  const projects = [project(1), { ...project(2), pinned: true }, project(3), project(4)];
  expect(quickProjects(projects, "app-1", new Set(["id-3", "id-2"])).map(p => p.id))
    .toEqual(["id-1", "id-2", "id-3"]);
  expect(quickProjects(projects, "app-2", new Set(["id-3"])).map(p => p.id))
    .toEqual(["id-2", "id-3"]);
});

test("visits reorder the all-project picker, but never pin a project or clutter the bar", () => {
  noteProjectVisit("app-3");
  noteProjectVisit("app-2");
  noteProjectVisit("app-3");
  const projects = [project(1), project(2), project(3)];
  expect(orderedProjects(projects).map(p => p.slug)).toEqual(["app-3", "app-2", "app-1"]);
  expect(quickProjects(projects, "app-1", new Set()).map(p => p.slug)).toEqual(["app-1"]);
});
