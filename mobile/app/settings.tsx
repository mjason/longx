import { Stack, useRouter } from "expo-router";
import Constants from "expo-constants";
import { Alert, Pressable, ScrollView, Switch, Text, View } from "react-native";
import { ListRow, SectionTitle } from "@/components/ListRow";
import { clearSession } from "@/lib/session";
import { syncNotify, useNotifyPreference } from "@/lib/notify";
import { useSession } from "@/lib/SessionContext";
import { t } from "@/lib/strings";
import { useUpdater } from "@/lib/updater";

// Settings: the server and this phone, background notifications, the app's
// own update, unpair.
export default function SettingsScreen() {
  const { session, setSession } = useSession();
  const router = useRouter();
  const s = t.settings;
  const notify = useNotifyPreference();
  const updater = useUpdater();
  const version = Constants.expoConfig?.version ?? "0.0.0";
  return (
    <>
      <Stack.Screen options={{ title: s.title }} />
      <ScrollView className="bg-background flex-1">
        <SectionTitle>{s.server}</SectionTitle>
        <ListRow title={session?.baseUrl ?? ""} subtitle={session?.serverVersion ? s.version(session.serverVersion) : null} />
        <ListRow title={session?.deviceName ?? ""} subtitle={s.device} />
        <SectionTitle>{s.notifications}</SectionTitle>
        <View className="border-border flex-row items-center gap-3 border-b px-4 py-3">
          <View className="flex-1">
            <Text className="text-foreground text-base">{s.notifications}</Text>
            <Text className="text-muted-foreground text-xs">{s.notificationsHint}</Text>
          </View>
          <Switch value={notify.enabled} onValueChange={(v) => void notify.setEnabled(v)} testID="notify-switch" />
        </View>
        <SectionTitle>{s.appVersion(version)}</SectionTitle>
        <ListRow
          title={updater.status.kind === "checking" ? s.checking : updater.status.kind === "available" ? s.newVersion(updater.status.release.tag) : updater.status.kind === "downloading" ? s.downloading : updater.status.kind === "upToDate" ? s.upToDate : s.checkUpdate}
          subtitle={updater.status.kind === "error" ? updater.status.message : null}
          onPress={() => (updater.status.kind === "available" ? void updater.install() : void updater.check(true))}
          testID="check-update"
        />
        <View className="px-4 py-6">
          <Pressable
            onPress={() =>
              Alert.alert(s.unpair, s.unpairHint, [
                { text: t.common.cancel, style: "cancel" },
                {
                  text: s.unpair,
                  style: "destructive",
                  onPress: () => {
                    void clearSession().then(() => {
                      void syncNotify();
                      setSession(null);
                      router.replace("/pair");
                    });
                  },
                },
              ])
            }
            className="border-destructive h-11 items-center justify-center rounded-lg border"
            testID="unpair"
          >
            <Text className="text-destructive font-medium">{s.unpair}</Text>
          </Pressable>
        </View>
      </ScrollView>
    </>
  );
}
