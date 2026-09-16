import { Redirect, Stack, useRouter } from "expo-router";
import { Settings } from "lucide-react-native";
import { Pressable, RefreshControl, ScrollView, Text, View } from "react-native";
import { Icon } from "@/components/ui/icon";
import { Empty, ListRow, SectionTitle } from "@/components/ListRow";
import { relativeTime } from "@/core/format";
import { useProjects, useRunningThreads } from "@/core/projects";
import { useSession } from "@/lib/SessionContext";
import { t } from "@/lib/strings";

// Home: what runs now (across projects, the ones waiting on the person
// first), then the projects — the web's welcome page.
export default function HomeScreen() {
  const { session } = useSession();
  const router = useRouter();
  const projects = useProjects();
  const running = useRunningThreads(3000);
  if (!session) return <Redirect href="/pair" />;
  const s = t.home;
  const rows = [...(running.data ?? [])].sort((a, b) => Number(b.waiting) - Number(a.waiting));

  return (
    <>
      <Stack.Screen
        options={{
          title: t.appName,
          headerRight: () => (
            <Pressable onPress={() => router.push("/settings")} hitSlop={12} accessibilityLabel={s.settings} testID="home-settings">
              <Icon as={Settings} className="text-foreground size-5" />
            </Pressable>
          ),
        }}
      />
      <ScrollView
        className="bg-background flex-1"
        refreshControl={<RefreshControl refreshing={projects.isRefetching} onRefresh={() => void projects.refetch()} />}
      >
        {rows.length > 0 ? (
          <View>
            <SectionTitle>{s.running}</SectionTitle>
            {rows.map((r) => (
              <ListRow
                key={r.id}
                title={r.title ?? r.preview ?? r.projectName}
                subtitle={`${r.projectName} · ${relativeTime(r.lastActivityAt)}`}
                trailing={
                  r.waiting ? (
                    <Text className="text-warning text-xs font-medium">{s.waiting}</Text>
                  ) : (
                    <Text className="text-muted-foreground text-xs">{t.project.status["active"]}</Text>
                  )
                }
                onPress={() => router.push(`/p/${r.projectSlug}/t/${r.id}`)}
                testID={`running-${r.id}`}
              />
            ))}
          </View>
        ) : null}
        <SectionTitle>{s.projects}</SectionTitle>
        {projects.isPending ? (
          <Empty>{t.common.loading}</Empty>
        ) : projects.isError ? (
          <Empty>{projects.error.message}</Empty>
        ) : projects.data.length === 0 ? (
          <Empty>{s.noProjects}</Empty>
        ) : (
          projects.data.map((p) => (
            <ListRow key={p.id} title={p.name} subtitle={p.rootPath} onPress={() => router.push(`/p/${p.slug}`)} testID={`project-${p.slug}`} />
          ))
        )}
      </ScrollView>
    </>
  );
}
