// Background notifications: on Android a foreground service (the native
// module in modules/longx-notify) keeps Longx's `notify` channel open and
// raises notifications — no FCM; elsewhere nothing yet (iOS: APNs later).
// The preference lives in the secure store next to the session.
import * as SecureStore from "expo-secure-store";
import { useCallback, useEffect, useState } from "react";
import { Platform } from "react-native";
import { transport } from "@/core/transport";

const KEY = "longx.notify";

type NativeNotify = { start: (socketUrl: string, token: string) => void; stop: () => void };

function native(): NativeNotify | null {
  if (Platform.OS !== "android") return null;
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { requireOptionalNativeModule } = require("expo-modules-core") as { requireOptionalNativeModule: (name: string) => NativeNotify | null };
    return requireOptionalNativeModule("LongxNotify");
  } catch {
    return null;
  }
}

export async function notifyEnabled(): Promise<boolean> {
  if (Platform.OS === "web") return false;
  return (await SecureStore.getItemAsync(KEY)) !== "off";
}

/** starts or stops the service to match the preference and the session */
export async function syncNotify(): Promise<void> {
  const mod = native();
  if (!mod) return;
  const { baseUrl, token } = transport();
  if (baseUrl && token && (await notifyEnabled())) {
    mod.start(`${baseUrl.replace(/^http/, "ws")}/socket/websocket?vsn=2.0.0&token=${encodeURIComponent(token)}`, token);
  } else {
    mod.stop();
  }
}

export function useNotifyPreference() {
  const [enabled, setEnabledState] = useState(true);
  useEffect(() => {
    void notifyEnabled().then(setEnabledState);
  }, []);
  const setEnabled = useCallback(async (value: boolean) => {
    setEnabledState(value);
    if (Platform.OS !== "web") await SecureStore.setItemAsync(KEY, value ? "on" : "off");
    await syncNotify();
  }, []);
  return { enabled, setEnabled };
}
