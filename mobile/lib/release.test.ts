import { newerVersion, releaseFrom } from "./release";

describe("release", () => {
  test("versions compare as numbers; a v prefix and a pre-release suffix are ignored", () => {
    expect(newerVersion("v0.2.0", "0.1.9")).toBe(true);
    expect(newerVersion("v1.0.0", "v0.99.99")).toBe(true);
    expect(newerVersion("v0.1.0", "0.1.0")).toBe(false);
    expect(newerVersion("v0.1.0", "0.1.1")).toBe(false);
    expect(newerVersion("garbage", "0.1.0")).toBe(false);
    expect(newerVersion("v0.1.2-rc1", "0.1.1")).toBe(true);
  });

  test("the release is read from GitHub's JSON; without an apk it is nothing", () => {
    const r = releaseFrom({
      tag_name: "v0.2.0",
      html_url: "https://github.com/mjason/longx/releases/tag/v0.2.0",
      body: "- notes",
      assets: [
        { name: "longx-0.2.0-linux-x86_64.tar.gz", browser_download_url: "https://x/tar", size: 1 },
        { name: "longx-android-v0.2.0.apk", browser_download_url: "https://x/apk", size: 5400000 },
      ],
    })!;
    expect(r.tag).toBe("v0.2.0");
    expect(r.apkUrl).toBe("https://x/apk");
    expect(r.apkName).toBe("longx-android-v0.2.0.apk");
    expect(releaseFrom({ tag_name: "v0.2.0", assets: [] })).toBeNull();
    expect(releaseFrom(null)).toBeNull();
  });
});
