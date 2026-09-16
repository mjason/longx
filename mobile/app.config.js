// app.json plus what a build decides: the version (the release tag, like the
// server's — LONGX_VERSION=v0.2.0 in release.yml) and the Android
// versionCode derived from it so the installer sees an upgrade.
const base = require("./app.json");

const version = (process.env.LONGX_VERSION ?? `v${base.expo.version}`).replace(/^v/, "");
const [major = 0, minor = 0, patch = 0] = version.split("-")[0].split(".").map((n) => Number(n) || 0);

module.exports = {
  ...base,
  expo: {
    ...base.expo,
    version,
    android: {
      ...base.expo.android,
      versionCode: major * 1_000_000 + minor * 1_000 + patch,
    },
    plugins: [...base.expo.plugins, "./plugins/withReleaseSigning"],
  },
};
