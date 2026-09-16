import { Stack, useLocalSearchParams } from "expo-router";
import { Alert, RefreshControl, ScrollView, Text } from "react-native";
import { Empty, ListRow } from "@/components/ListRow";
import { relativeTime } from "@/core/format";
import { useRestoreFiles, useTurns } from "@/core/projects";
import { t } from "@/lib/strings";

// A thread's turns with their git bookmarks; a turn that started from a
// commit can have the files restored to that point (a safety commit first).
export default function HistoryScreen() {
  const { thread } = useLocalSearchParams<{ slug: string; thread?: string }>();
  const turns = useTurns(thread);
  const restore = useRestoreFiles(thread);
  const s = t.history;
  return (
    <>
      <Stack.Screen options={{ title: s.title }} />
      <ScrollView className="bg-background flex-1" refreshControl={<RefreshControl refreshing={turns.isRefetching} onRefresh={() => void turns.refetch()} />}>
        {!thread ? (
          <Empty>{s.empty}</Empty>
        ) : turns.isPending ? (
          <Empty>{t.common.loading}</Empty>
        ) : turns.isError ? (
          <Empty>{turns.error.message}</Empty>
        ) : turns.data.length === 0 ? (
          <Empty>{s.empty}</Empty>
        ) : (
          [...turns.data].reverse().map((turn) => (
            <ListRow
              key={turn.id}
              title={turn.userText ?? ""}
              subtitle={`${s.status[turn.status] ?? turn.status} · ${relativeTime(turn.startedAt)}${turn.commitBefore ? ` · ${turn.commitBefore.slice(0, 8)}` : ""}`}
              trailing={turn.commitBefore ? <Text className="text-primary text-xs">{s.restore}</Text> : undefined}
              onPress={
                turn.commitBefore
                  ? () =>
                      Alert.alert(s.restoreTitle, s.restoreHint, [
                        { text: t.common.cancel, style: "cancel" },
                        { text: s.restoreConfirm, onPress: () => restore.mutate({ turnId: turn.id }) },
                      ])
                  : undefined
              }
              testID={`turn-${turn.id}`}
            />
          ))
        )}
      </ScrollView>
    </>
  );
}
