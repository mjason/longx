// Metro for the Longx app. Two things beyond Expo's default:
//  - the web client's DOM-free core (../assets/js/core, the generated RPC
//    client) is part of this bundle: it is watched, `@/` inside it resolves
//    to ../assets/js (inside the app `@/` is the app root), its
//    `@assistant-ui/react` import resolves to the React Native package, and
//    every package resolves from this app's node_modules so there is one
//    React, one query client, one assistant-ui store;
//  - Uniwind (Tailwind classes on React Native) must wrap everything.
const path = require("node:path");
const { getDefaultConfig } = require("expo/metro-config");
const { withUniwindConfig } = require("uniwind/metro");

const app = __dirname;
const core = path.resolve(app, "../assets/js");

const config = getDefaultConfig(app);
config.watchFolders = [...(config.watchFolders ?? []), core];

const defaultResolve = config.resolver.resolveRequest;
config.resolver.resolveRequest = (context, moduleName, platform) => {
  const fromCore = context.originModulePath.startsWith(core + path.sep);
  let name = moduleName;
  let ctx = context;
  if (name.startsWith("@/")) {
    // `@/core/…` and the generated client live in the web client; the rest is this app
    const rest = name.slice(2);
    const inCore = fromCore || rest.startsWith("core/") || rest === "ash_rpc" || rest === "ash_types";
    name = path.join(inCore ? core : app, rest);
  } else if (fromCore && !name.startsWith(".") && !path.isAbsolute(name)) {
    // a package imported by the shared core resolves from this app's
    // node_modules (one React, one query client, one assistant-ui store),
    // and assistant-ui's web package is the native one here
    if (name === "@assistant-ui/react" || name.startsWith("@assistant-ui/react/")) {
      name = name.replace("@assistant-ui/react", "@assistant-ui/react-native");
    }
    ctx = { ...context, originModulePath: path.join(app, "package.json") };
  }
  return (defaultResolve ?? context.resolveRequest)(ctx, name, platform);
};

module.exports = withUniwindConfig(config, {
  cssEntryFile: "./global.css",
  dtsFile: "./uniwind-types.d.ts",
});
