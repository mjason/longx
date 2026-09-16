import { Stack, useRouter } from "expo-router";
import { useState } from "react";
import { KeyboardAvoidingView, Platform, Pressable, ScrollView, Text, TextInput, View } from "react-native";
import { syncNotify } from "@/lib/notify";
import { pairWithServer, saveSession } from "@/lib/session";
import { useSession } from "@/lib/SessionContext";
import { t } from "@/lib/strings";
import * as Device from "expo-device";

// The first screen: the server's address and the six-digit code from
// Settings → 移动端. A success stores the device token and goes home.
export default function PairScreen() {
  const router = useRouter();
  const { setSession } = useSession();
  const [server, setServer] = useState("");
  const [code, setCode] = useState("");
  const [name, setName] = useState(Device.deviceName ?? (Platform.OS === "ios" ? "iPhone" : "Android"));
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const s = t.pair;

  const submit = async () => {
    setBusy(true);
    setError(null);
    try {
      const session = await pairWithServer(server, code.trim(), name.trim() || "手机");
      await saveSession(session);
      setSession(session);
      void syncNotify();
      router.replace("/");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <KeyboardAvoidingView behavior={Platform.OS === "ios" ? "padding" : undefined} className="flex-1">
      <Stack.Screen options={{ title: s.title, headerBackVisible: false }} />
      <ScrollView className="flex-1 bg-background" contentContainerClassName="gap-4 px-5 py-6" keyboardShouldPersistTaps="handled">
        <Text className="text-muted-foreground text-sm leading-6">{s.hint}</Text>
        <Field label={s.server}>
          <TextInput
            value={server}
            onChangeText={setServer}
            placeholder={s.serverPlaceholder}
            placeholderTextColor="#9aa0ad"
            autoCapitalize="none"
            autoCorrect={false}
            keyboardType="url"
            className="border-input bg-card text-foreground h-12 rounded-lg border px-3 font-mono text-base"
            testID="pair-server"
          />
        </Field>
        <Field label={s.code}>
          <TextInput
            value={code}
            onChangeText={setCode}
            placeholder={s.codePlaceholder}
            placeholderTextColor="#9aa0ad"
            keyboardType="number-pad"
            maxLength={6}
            className="border-input bg-card text-foreground h-12 rounded-lg border px-3 font-mono text-2xl tracking-[6px]"
            testID="pair-code"
          />
        </Field>
        <Field label={s.device}>
          <TextInput value={name} onChangeText={setName} className="border-input bg-card text-foreground h-12 rounded-lg border px-3 text-base" />
        </Field>
        {error ? <Text className="text-destructive text-sm">{error}</Text> : null}
        <Pressable
          onPress={() => void submit()}
          disabled={busy || !server || code.length !== 6}
          className="bg-primary active:bg-primary/90 h-12 items-center justify-center rounded-lg disabled:opacity-50"
          testID="pair-submit"
        >
          <Text className="text-primary-foreground text-base font-medium">{busy ? s.working : s.submit}</Text>
        </Pressable>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <View className="gap-1.5">
      <Text className="text-foreground text-sm font-medium">{label}</Text>
      {children}
    </View>
  );
}
