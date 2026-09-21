// The formula renderer as a lazy chunk: KaTeX, rehype-katex and KaTeX's
// stylesheet (with its fonts) are fetched once, the first time a
// MarkdownText mounts, and kept; until the chunk is in, a formula shows as
// its TeX. `rehypePlugins` re-renders every markdown part when it arrives.
import { useEffect, useState } from "react";
import type { PluggableList } from "unified";

let loaded: PluggableList | null = null;
let loading: Promise<PluggableList> | null = null;
const listeners = new Set<() => void>();

export function loadMath(): Promise<PluggableList> {
  if (loaded) return Promise.resolve(loaded);
  if (!loading) {
    loading = Promise.all([import("rehype-katex"), import("katex/dist/katex.min.css")]).then(([plugin]) => {
      loaded = [plugin.default];
      listeners.forEach((l) => l());
      return loaded;
    });
  }
  return loading;
}

/** the rehype plugins for math: `[]` until the renderer is in, then KaTeX's */
export function useMath(): PluggableList {
  const [plugins, setPlugins] = useState<PluggableList>(loaded ?? []);
  useEffect(() => {
    if (loaded) {
      setPlugins(loaded);
      return;
    }
    const listener = () => setPlugins(loaded!);
    listeners.add(listener);
    void loadMath();
    return () => {
      listeners.delete(listener);
    };
  }, []);
  return plugins;
}
