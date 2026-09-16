import { Stack, useLocalSearchParams } from "expo-router";
import { View } from "react-native";
import { WebView } from "react-native-webview";
import { useProject } from "@/core/projects";
import { transport } from "@/core/transport";
import { usePalette } from "@/lib/theme";

// A file in the editor: the server's own CodeMirror page (/embed/editor),
// the one piece of the web client a phone borrows as is — there is no
// React Native CodeMirror. The WebView has its own session with the server.
export default function FileScreen() {
  const { slug, path } = useLocalSearchParams<{ slug: string; path: string }>();
  const project = useProject(slug);
  const colors = usePalette();
  const url = project.data ? `${transport().baseUrl}/embed/editor/${project.data.id}?path=${encodeURIComponent(path)}` : null;
  return (
    <View style={{ flex: 1, backgroundColor: colors.ground }}>
      <Stack.Screen options={{ title: path.split("/").pop() ?? path }} />
      {url ? <WebView source={{ uri: url }} style={{ flex: 1, backgroundColor: colors.ground }} setSupportMultipleWindows={false} allowsBackForwardNavigationGestures={false} /> : null}
    </View>
  );
}
