// The `present` / `prompt_user` tool schemas the kernel declares
// (Longx.Agent.Plugs.Present) come from the same component vocabulary the
// client renders with — @assistant-ui/react-generative-ui's default library —
// so the model can only name components the page can draw. Written to
// priv/agent/present.json; `--check` fails when the file is out of date
// (precommit runs it next to `ash_typescript.codegen --check`).
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

process.env.NODE_ENV = "production";
const { JSONGenerativeUI, defaultGenerativeUILibrary } = await import("@assistant-ui/react-generative-ui");
const { version } = JSON.parse(readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), "../node_modules/@assistant-ui/react-generative-ui/package.json"), "utf8"));

const gui = new JSONGenerativeUI({ library: defaultGenerativeUILibrary });
const pick = ({ description, parameters }) => ({ description, parameters });
const doc = {
  version,
  components: Object.keys(defaultGenerativeUILibrary).sort(),
  present: pick(gui.present()),
  prompt_user: pick(gui.promptUser()),
};
const text = JSON.stringify(doc, null, 2) + "\n";
const out = resolve(dirname(fileURLToPath(import.meta.url)), "../../priv/agent/present.json");

if (process.argv.includes("--check")) {
  let current = "";
  try { current = readFileSync(out, "utf8"); } catch {}
  if (current !== text) {
    console.error(`priv/agent/present.json is out of date — run \`npm run present-schema\` in assets/`);
    process.exit(1);
  }
  console.log("present.json up to date");
} else {
  writeFileSync(out, text);
  console.log(`wrote ${out} (${doc.components.length} components, package ${version})`);
}
