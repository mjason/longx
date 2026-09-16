// jest-expo's preset, plus: the shared web core (../assets/js) resolves like
// in Metro, ESM packages are transformed (assistant-ui, lucide's .mjs), and
// the secure store is faked (test/setup.ts).
const path = require("node:path");
const preset = require("jest-expo/jest-preset");

const babel = preset.transform["\\.[jt]sx?$"];

module.exports = {
  ...preset,
  roots: ["<rootDir>", "<rootDir>/../assets/js"],
  testMatch: ["<rootDir>/**/*.test.ts", "<rootDir>/**/*.test.tsx"],
  moduleNameMapper: {
    ...(preset.moduleNameMapper ?? {}),
    "^@assistant-ui/react$": path.join(__dirname, "node_modules/@assistant-ui/react-native"),
    // one copy of each, whichever side imports it (the web core has its own node_modules)
    "^react$": path.join(__dirname, "node_modules/react"),
    "^react/(.*)$": path.join(__dirname, "node_modules/react/$1"),
    "^react-native$": path.join(__dirname, "node_modules/react-native"),
    "^@tanstack/react-query$": path.join(__dirname, "node_modules/@tanstack/react-query"),
    "^phoenix$": path.join(__dirname, "node_modules/phoenix"),
    "^@assistant-ui/react-native$": path.join(__dirname, "node_modules/@assistant-ui/react-native"),
    "^@/(.*)$": ["<rootDir>/$1", "<rootDir>/../assets/js/$1"],
    "\\.css$": "<rootDir>/test/styleMock.js",
  },
  transform: {
    ...preset.transform,
    "\\.m?[jt]sx?$": babel,
  },
  transformIgnorePatterns: [
    "/node_modules/(?!(.pnpm|react-native|@react-native|@react-native-community|expo|@expo|@expo-google-fonts|react-navigation|@react-navigation|@sentry/react-native|native-base|standard-navigation|@assistant-ui|assistant-stream|assistant-cloud|lucide-react-native|react-native-svg|uniwind|react-native-marked|react-native-webview|react-native-safe-area-context|react-native-screens|cn|nanoid|secure-json-parse|zod))",
    "/node_modules/react-native-reanimated/plugin/",
    "/node_modules/@react-native/babel-preset/",
  ],
  setupFiles: [...(preset.setupFiles ?? []), "<rootDir>/test/setup.ts"],
};
