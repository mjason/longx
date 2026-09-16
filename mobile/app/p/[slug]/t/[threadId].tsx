import { AssistantRuntimeProvider, useAui } from "@assistant-ui/react-native";
import { Stack, useLocalSearchParams, useRouter } from "expo-router";
import { FolderTree, GitBranch, History } from "lucide-react-native";
import { useCallback, useEffect, useRef } from "react";
import { Alert, Pressable, Text, View } from "react-native";
import { Thread } from "@/components/assistant-ui/elements/thread.aui";
import { Icon } from "@/components/ui/icon";
import { ChatContext } from "@/components/chat/ChatContext";
import { CodexTool } from "@/components/chat/CodexTool";
import { ComposerLeading, ComposerTrailing } from "@/components/chat/ComposerRail";
import type { DirtyChange, DirtyDecision } from "@/core/chat/adapter";
import { useCodexRuntime } from "@/core/chat/runtime";
import { useProject } from "@/core/projects";
import { t } from "@/lib/strings";

// The thread: assistant-ui's native Thread element over the same codex
// runtime as the web (core/chat/runtime — the codex events, the messages,
// the adapter are shared), our renderers for codex's items, our rail.
// `threadId` "new" is a chat the first message creates.
export default function ThreadScreen() {
  const { slug, threadId } = useLocalSearchParams<{ slug: string; threadId: string }>();
  const project = useProject(slug);
  if (project.isPending)
    return (
      <View className="bg-background flex-1 items-center justify-center">
        <Text className="text-muted-foreground">{t.common.loading}</Text>
      </View>
    );
  if (project.isError)
    return (
      <View className="bg-background flex-1 items-center justify-center px-6">
        <Text className="text-destructive">{project.error.message}</Text>
      </View>
    );
  const p = project.data;
  return (
    <Chat
      projectId={p.id}
      slug={slug}
      threadId={threadId === "new" ? undefined : threadId}
      defaultModelId={p.modelId ?? null}
      defaults={{ sandbox: p.sandbox, approvalPolicy: p.approvalPolicy, networkAccess: p.networkAccess, webSearch: p.webSearch, multiAgent: p.multiAgent, autoReview: p.autoReview }}
    />
  );
}

type ChatProps = {
  projectId: string;
  slug: string;
  threadId: string | undefined;
  defaultModelId: string | null;
  defaults: Parameters<typeof useCodexRuntime>[0]["defaults"];
};

function Chat({ projectId, slug, threadId, defaultModelId, defaults }: ChatProps) {
  const router = useRouter();
  const retracted = useRef<string | null>(null);
  const onOpenThread = useCallback(
    (id: string | null) => router.replace(id ? `/p/${slug}/t/${id}` : `/p/${slug}/t/new`),
    [router, slug],
  );
  // the project's policy is "ask": a native dialog decides
  const onDirtyTree = useCallback(
    (changes: DirtyChange[]) =>
      new Promise<DirtyDecision>((resolve) => {
        const s = t.thread;
        Alert.alert(s.dirtyTitle, `${s.dirtyHint}\n\n${changes.map((c) => `${c.status} ${c.path}`).join("\n")}`, [
          { text: s.cancel, style: "cancel", onPress: () => resolve(null) },
          { text: s.dirtyIgnore, onPress: () => resolve("ignore") },
          { text: s.dirtyCommit, onPress: () => resolve("commit") },
        ]);
      }),
    [],
  );
  const onRetract = useCallback((text: string) => {
    retracted.current = text;
  }, []);
  const chat = useCodexRuntime({ projectId, defaults, defaultModelId, threadId, onOpenThread, onDirtyTree, onRetract });

  return (
    <ChatContext.Provider value={chat}>
      <AssistantRuntimeProvider runtime={chat.runtime}>
        <Stack.Screen
          options={{
            title: (chat.thread?.title ?? chat.thread?.preview ?? t.project.newThread).slice(0, 18),
            headerRight: () => (
              <View className="flex-row items-center gap-4">
                {(
                  [
                    [FolderTree, "files", t.project.files],
                    [GitBranch, "git", t.project.git],
                    [History, "history", t.project.history],
                  ] as const
                ).map(([icon, path, label]) => (
                  <Pressable key={path} onPress={() => router.push(`/p/${slug}/${path}${path === "history" && chat.thread ? `?thread=${chat.thread.id}` : ""}`)} hitSlop={8} accessibilityLabel={label}>
                    <Icon as={icon} className="text-foreground size-5" />
                  </Pressable>
                ))}
              </View>
            ),
          }}
        />
        <ComposerBridge retracted={retracted} />
        {chat.disabledReason ? (
          <View className="bg-warning/10 px-4 py-2">
            <Text className="text-warning text-xs">{t.thread.disabled(chat.disabledReason)}</Text>
          </View>
        ) : null}
        {chat.error ? (
          <View className="bg-destructive/10 px-4 py-2">
            <Text className="text-destructive text-xs">{chat.error}</Text>
          </View>
        ) : null}
        <Thread components={{ Welcome, ToolFallback: CodexTool, ComposerLeading, ComposerTrailing }} />
      </AssistantRuntimeProvider>
    </ChatContext.Provider>
  );
}

// a stop before anything came back: the text goes back into the composer
function ComposerBridge({ retracted }: { retracted: React.MutableRefObject<string | null> }) {
  const aui = useAui();
  useEffect(() => {
    const id = setInterval(() => {
      if (retracted.current !== null) {
        aui.composer.setText(retracted.current);
        retracted.current = null;
      }
    }, 200);
    return () => clearInterval(id);
  }, [aui, retracted]);
  return null;
}

function Welcome() {
  return (
    <View className="mb-6 items-center px-4">
      <Text className="text-foreground text-center text-2xl font-medium tracking-tight">{t.thread.welcome}</Text>
      <Text className="text-muted-foreground mt-2 text-center text-sm">{t.thread.welcomeHint}</Text>
    </View>
  );
}
