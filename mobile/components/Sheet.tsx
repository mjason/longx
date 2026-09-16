import { Check } from "lucide-react-native";
import type { ReactNode } from "react";
import { Modal, Pressable, ScrollView, Text, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { Icon } from "@/components/ui/icon";

/** a bottom sheet — the phone's answer to a popover — built on the plain Modal */
export function Sheet({ open, onClose, title, children }: { open: boolean; onClose: () => void; title?: string; children: ReactNode }) {
  const insets = useSafeAreaInsets();
  return (
    <Modal visible={open} transparent animationType="slide" onRequestClose={onClose}>
      <Pressable className="flex-1 justify-end bg-black/40" onPress={onClose} testID="sheet-backdrop">
        <Pressable onPress={() => {}} className="bg-card max-h-[80%] rounded-t-3xl" style={{ paddingBottom: insets.bottom + 8 }}>
          <View className="bg-muted-foreground/30 mt-2 h-1 w-10 self-center rounded-full" />
          {title ? <Text className="text-foreground px-6 pb-2 pt-3 text-base font-semibold">{title}</Text> : null}
          <ScrollView bounces={false}>{children}</ScrollView>
        </Pressable>
      </Pressable>
    </Modal>
  );
}

export type SheetOption = { id: string; label: string; detail?: string | null; danger?: boolean };
export type SheetSection = { label?: string; options: SheetOption[] };

/** a single choice among sections of options; the pick closes the sheet */
export function PickSheet({
  open,
  onClose,
  title,
  sections,
  selected,
  onPick,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  sections: SheetSection[];
  selected: string | null;
  onPick: (id: string) => void;
}) {
  return (
    <Sheet open={open} onClose={onClose} title={title}>
      {sections.map((section, i) => (
        <View key={section.label ?? i}>
          {section.label ? <Text className="text-muted-foreground px-6 pb-1 pt-3 text-xs font-medium">{section.label}</Text> : null}
          {section.options.map((o) => (
            <Pressable
              key={o.id}
              onPress={() => {
                onPick(o.id);
                onClose();
              }}
              className="active:bg-accent min-h-14 flex-row items-center gap-3 px-6 py-2"
              testID={`pick-${o.id}`}
            >
              <View className="min-w-0 flex-1">
                <Text className={`text-base ${o.danger ? "text-destructive" : "text-foreground"}`}>{o.label}</Text>
                {o.detail ? <Text className="text-muted-foreground text-xs">{o.detail}</Text> : null}
              </View>
              {o.id === selected ? <Icon as={Check} className="text-primary size-5" /> : null}
            </Pressable>
          ))}
        </View>
      ))}
    </Sheet>
  );
}
