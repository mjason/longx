// The renderer as a lazy chunk: MathJax and the font are a megabyte the
// page fetches once, the first time a MarkdownText mounts, and keeps; until
// the chunk is in, a formula shows as its TeX. `rehypePlugins` re-renders
// every markdown part when the plugin arrives.
import { useEffect, useState } from "react";
import type { PluggableList } from "unified";

let loaded: PluggableList | null = null;
let loading: Promise<PluggableList> | null = null;
const listeners = new Set<() => void>();

export function loadMathjax(): Promise<PluggableList> {
  if (loaded) return Promise.resolve(loaded);
  if (!loading) {
    loading = Promise.all([import("./rehype-mathjax"), import("./mathjax")]).then(async ([plugin, mathjax]) => {
      await mathjax.ready;
      loaded = [plugin.rehypeMathjax];
      listeners.forEach((l) => l());
      return loaded;
    });
  }
  return loading;
}

/** the rehype plugins for math: `[]` until the renderer is in, then MathJax's */
export function useMathjax(): PluggableList {
  const [plugins, setPlugins] = useState<PluggableList>(loaded ?? []);
  useEffect(() => {
    if (loaded) {
      setPlugins(loaded);
      return;
    }
    const listener = () => setPlugins(loaded!);
    listeners.add(listener);
    void loadMathjax();
    return () => {
      listeners.delete(listener);
    };
  }, []);
  return plugins;
}
