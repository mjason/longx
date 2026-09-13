// Which CodeMirror language a file gets: @codemirror/language-data knows
// ~150 by extension and file name and loads each one lazily, so the
// editor bundle stays small and a Rust file costs a Rust mode only when
// one is opened.
import { LanguageDescription } from "@codemirror/language";
import { languages } from "@codemirror/language-data";

// Elixir is not in language-data; codemirror-lang-elixir is, lazily like the rest
const elixir = LanguageDescription.of({
  name: "Elixir",
  extensions: ["ex", "exs", "heex", "eex", "leex"],
  filename: /^mix\.lock$/,
  load: () => import("codemirror-lang-elixir").then((m) => m.elixir()),
});

const all = [elixir, ...languages];

export function languageFor(path: string): LanguageDescription | undefined {
  const name = path.split("/").at(-1) ?? path;
  return LanguageDescription.matchFilename(all, name) ?? undefined;
}
