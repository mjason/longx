import { Stack, useLocalSearchParams, useRouter } from "expo-router";
import { File, Folder } from "lucide-react-native";
import { RefreshControl, ScrollView } from "react-native";
import { Icon } from "@/components/ui/icon";
import { Empty, ListRow } from "@/components/ListRow";
import { formatBytes } from "@/core/format";
import { useProject } from "@/core/projects";
import { useFiles } from "@/core/workspace";
import { t } from "@/lib/strings";

// The file tree, one directory a screen (folders first); a file opens the
// editor (a WebView on the server's embedded CodeMirror).
export default function FilesScreen() {
  const { slug, path = "" } = useLocalSearchParams<{ slug: string; path?: string }>();
  const router = useRouter();
  const project = useProject(slug);
  const files = useFiles(project.data?.id ?? "", path, !!project.data);
  const title = path ? path.split("/").pop()! : t.files.title;
  return (
    <>
      <Stack.Screen options={{ title }} />
      <ScrollView className="bg-background flex-1" refreshControl={<RefreshControl refreshing={files.isRefetching} onRefresh={() => void files.refetch()} />}>
        {files.isPending ? (
          <Empty>{t.common.loading}</Empty>
        ) : files.isError ? (
          <Empty>{files.error.message}</Empty>
        ) : files.data.length === 0 ? (
          <Empty>{t.files.empty}</Empty>
        ) : (
          files.data.map((e) => (
            <ListRow
              key={e.path}
              title={e.name}
              subtitle={e.kind === "file" ? formatBytes(e.size) : null}
              trailing={<Icon as={e.kind === "dir" ? Folder : File} className="text-muted-foreground size-4" />}
              onPress={() =>
                e.kind === "dir"
                  ? router.push({ pathname: "/p/[slug]/files", params: { slug, path: e.path } })
                  : router.push({ pathname: "/p/[slug]/file", params: { slug, path: e.path } })
              }
              testID={`entry-${e.path}`}
            />
          ))
        )}
      </ScrollView>
    </>
  );
}
