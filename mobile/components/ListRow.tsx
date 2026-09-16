import { ChevronRight } from "lucide-react-native";
import type { ReactNode } from "react";
import { Pressable, Text, View } from "react-native";
import { Icon } from "@/components/ui/icon";

/** one row of a list: a title, a second line, a chevron; the app's lists are all this */
export function ListRow({
  title,
  subtitle,
  trailing,
  onPress,
  testID,
}: {
  title: string;
  subtitle?: string | null;
  trailing?: ReactNode;
  onPress?: () => void;
  testID?: string;
}) {
  return (
    <Pressable
      onPress={onPress}
      disabled={!onPress}
      className="border-border active:bg-accent min-h-14 flex-row items-center gap-3 border-b px-4 py-2.5"
      testID={testID}
    >
      <View className="min-w-0 flex-1">
        <Text className="text-foreground text-base" numberOfLines={1}>
          {title}
        </Text>
        {subtitle ? (
          <Text className="text-muted-foreground mt-0.5 text-xs" numberOfLines={1}>
            {subtitle}
          </Text>
        ) : null}
      </View>
      {trailing}
      {onPress ? <Icon as={ChevronRight} className="text-muted-foreground size-4" /> : null}
    </Pressable>
  );
}

export function SectionTitle({ children }: { children: string }) {
  return <Text className="text-muted-foreground bg-background px-4 pb-1 pt-4 text-xs font-medium uppercase tracking-wide">{children}</Text>;
}

export function Empty({ children }: { children: string }) {
  return <Text className="text-muted-foreground px-4 py-8 text-center text-sm">{children}</Text>;
}
