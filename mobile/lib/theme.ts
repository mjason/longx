// the two palettes of global.css, for the places Uniwind cannot reach
// (navigation headers, the status bar)
import { useColorScheme } from "react-native";

export const palette = {
  light: { ground: "#ffffff", frame: "#f3f4f7", text: "#1c1e24", muted: "#6b7280", accent: "#1b5cf0", border: "#e5e7eb" },
  dark: { ground: "#1c1e24", frame: "#15171c", text: "#e6e8ee", muted: "#9aa0ad", accent: "#2f7cf6", border: "#2e323c" },
};

export function usePalette() {
  const scheme = useColorScheme();
  return scheme === "dark" ? palette.dark : palette.light;
}
