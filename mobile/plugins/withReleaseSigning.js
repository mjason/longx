// A release build signed with the repository's key when the environment
// names one (LONGX_KEYSTORE / _PASSWORD / LONGX_KEY_ALIAS / LONGX_KEY_PASSWORD
// — CI's secrets, or ~/.longx-android/release.env locally); the debug key
// otherwise. Updates only install over the same key, so releases share one.
const { withAppBuildGradle } = require("expo/config-plugins");

module.exports = function withReleaseSigning(config) {
  return withAppBuildGradle(config, (mod) => {
    if (!process.env.LONGX_KEYSTORE) return mod;
    let gradle = mod.modResults.contents;
    gradle = gradle.replace(
      /signingConfigs \{\n\s*debug \{[\s\S]*?\n\s*\}\n\s*\}/,
      (block) =>
        block.replace(
          /\n\s*\}\n\s*\}$/,
          `\n        }\n        release {\n            storeFile file(System.getenv("LONGX_KEYSTORE"))\n            storePassword System.getenv("LONGX_KEYSTORE_PASSWORD")\n            keyAlias System.getenv("LONGX_KEY_ALIAS")\n            keyPassword System.getenv("LONGX_KEY_PASSWORD")\n        }\n    }`,
        ),
    );
    gradle = gradle.replace(/(release \{[\s\S]*?signingConfig signingConfigs\.)debug/, "$1release");
    mod.modResults.contents = gradle;
    return mod;
  });
};
