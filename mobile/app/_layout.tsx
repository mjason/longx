import "../global.css";
import { QueryClientProvider } from "@tanstack/react-query";
import { Stack } from "expo-router";
import { StatusBar } from "expo-status-bar";
import { useEffect, useState } from "react";
import { View } from "react-native";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { queryClient } from "@/lib/queryClient";
import { syncNotify } from "@/lib/notify";
import { loadSession, type Session } from "@/lib/session";
import { SessionContext } from "@/lib/SessionContext";
import { usePalette } from "@/lib/theme";

// The root: the paired server (secure store → the core's transport) is
// loaded before anything renders; the query client and the navigation
// stack wrap every screen. Screens redirect to /pair when there is none.
export default function RootLayout() {
  const [session, setSession] = useState<Session | null | undefined>(undefined);
  const colors = usePalette();
  useEffect(() => {
    loadSession().then((s) => {
      setSession(s);
      void syncNotify();
    });
  }, []);
  if (session === undefined) return null;
  return (
    <View style={{ flex: 1, backgroundColor: colors.ground }}>
      <SafeAreaProvider>
        <QueryClientProvider client={queryClient}>
          <SessionContext.Provider value={{ session, setSession }}>
            <StatusBar style="auto" />
            <Stack
              screenOptions={{
                headerStyle: { backgroundColor: colors.frame },
                headerTintColor: colors.text,
                headerTitleStyle: { fontWeight: "600" },
                headerShadowVisible: false,
                contentStyle: { backgroundColor: colors.ground },
              }}
            />
          </SessionContext.Provider>
        </QueryClientProvider>
      </SafeAreaProvider>
    </View>
  );
}
