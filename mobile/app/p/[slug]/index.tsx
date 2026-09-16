import { Stack, useLocalSearchParams, useRouter } from "expo-router";
import { FolderTree, GitBranch, History, Plus } from "lucide-react-native";
import { Pressable, RefreshControl, ScrollView, Text, View } from "react-native";
import { Icon } from "@/components/ui/icon";
import { Empty, ListRow } from "@/components/ListRow";
import { relativeTime } from "@/core/format";
import { useProject, useThreads } from "@/core/projects";
import { t } from "@/lib/strings";

// A project: its threads, newest first, and the doors to its tools.
export default function ProjectScreen() {
  const { slug } = useLocalSearchParams<{ slug: string }>();
  const router = useRouter();
  const project = useProject(slug);
  const threads = useThreads(project.data?.id);
  const s = t.project;

  return (
    <>
      <Stack.Screen
        options={{
          title: project.data?.name ?? slug,
          headerRight: () => (
            <Pressable onPress={() => router.push(`/p/${slug}/t/new`)} hitSlop={12} accessibilityLabel={s.newThread} testID="new-thread">
              <Icon as={Plus} className="text-foreground size-5" />
            </Pressable>
          ),
        }}
      />
      <ScrollView
        className="bg-background flex-1"
        refreshControl={<RefreshControl refreshing={threads.isRefetching} onRefresh={() => void threads.refetch()} />}
      >
        <View className="border-border flex-row border-b">
          {(
            [
              [FolderTree, s.files, "files"],
              [GitBranch, s.git, "git"],
              [History, s.history, "history"],
            ] as const
          ).map(([icon, label, path]) => (
            <Pressable
              key={path}
              onPress={() => router.push(`/p/${slug}/${path}`)}
              className="active:bg-accent flex-1 items-center gap-1 py-3"
              testID={`tool-${path}`}
            >
              <Icon as={icon} className="text-muted-foreground size-5" />
              <Text className="text-foreground text-xs">{label}</Text>
            </Pressable>
          ))}
        </View>
        {threads.isPending ? (
          <Empty>{t.common.loading}</Empty>
        ) : threads.isError ? (
          <Empty>{threads.error.message}</Empty>
        ) : threads.data.length === 0 ? (
          <Empty>{s.noThreads}</Empty>
        ) : (
          threads.data.map((th) => (
            <ListRow
              key={th.id}
              title={th.title ?? th.preview ?? s.newThread}
              subtitle={`${s.status[th.status] ?? th.status} · ${relativeTime(th.lastActivityAt)}`}
              onPress={() => router.push(`/p/${slug}/t/${th.id}`)}
              testID={`thread-${th.id}`}
            />
          ))
        )}
      </ScrollView>
    </>
  );
}
