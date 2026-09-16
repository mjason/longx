import { Stack, useLocalSearchParams, useRouter } from "expo-router";
import { useState } from "react";
import { Pressable, RefreshControl, ScrollView, Text, TextInput, View } from "react-native";
import { Empty, ListRow, SectionTitle } from "@/components/ListRow";
import { useProject } from "@/core/projects";
import { useGitActions, useGitChanges, useGitLog } from "@/core/workspace";
import { t } from "@/lib/strings";

// Git: the branch, the changes with a commit box, the recent history —
// GitHub Desktop's changes tab, read-mostly on a phone.
export default function GitScreen() {
  const { slug } = useLocalSearchParams<{ slug: string }>();
  const router = useRouter();
  const project = useProject(slug);
  const id = project.data?.id ?? "";
  const changes = useGitChanges(id, { poll: false });
  const log = useGitLog(id, 30, 0, !!id);
  const actions = useGitActions(id);
  const [summary, setSummary] = useState("");
  const s = t.git;
  const data = changes.data;
  return (
    <>
      <Stack.Screen options={{ title: s.title }} />
      <ScrollView className="bg-background flex-1" refreshControl={<RefreshControl refreshing={changes.isRefetching} onRefresh={() => void changes.refetch()} />} keyboardShouldPersistTaps="handled">
        {!data ? (
          <Empty>{changes.isError ? changes.error.message : t.common.loading}</Empty>
        ) : !data.repository ? (
          <Empty>{s.notRepo}</Empty>
        ) : (
          <>
            <ListRow title={data.branch ?? "HEAD"} subtitle={`${s.branch} · ${data.head?.slice(0, 8) ?? ""}`} />
            <SectionTitle>{s.changes}</SectionTitle>
            {data.changes.length === 0 ? (
              <Empty>{s.clean}</Empty>
            ) : (
              <>
                {data.changes.map((c) => (
                  <ListRow key={c.path} title={c.path} subtitle={c.status} onPress={() => router.push({ pathname: "/p/[slug]/file", params: { slug, path: c.path } })} />
                ))}
                <View className="gap-2 px-4 py-3">
                  <TextInput value={summary} onChangeText={setSummary} placeholder={s.summary} placeholderTextColor="#9aa0ad" className="border-input bg-card text-foreground h-11 rounded-lg border px-3 text-base" testID="commit-summary" />
                  <Pressable
                    onPress={() => actions.commit.mutate({ paths: data.changes.map((c) => c.path), message: summary }, { onSuccess: () => setSummary("") })}
                    disabled={!summary.trim() || actions.commit.isPending}
                    className="bg-primary h-11 items-center justify-center rounded-lg disabled:opacity-50"
                    testID="commit"
                  >
                    <Text className="text-primary-foreground font-medium">{s.commit}</Text>
                  </Pressable>
                  {actions.commit.isError ? <Text className="text-destructive text-xs">{actions.commit.error.message}</Text> : null}
                </View>
              </>
            )}
            <SectionTitle>{s.log}</SectionTitle>
            {(log.data ?? []).map((c) => (
              <ListRow key={c.sha} title={c.subject} subtitle={`${c.sha.slice(0, 8)} · ${c.author}`} />
            ))}
          </>
        )}
      </ScrollView>
    </>
  );
}
