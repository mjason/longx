// The web client's core (../assets/js/core) imports `@assistant-ui/react`;
// Metro resolves that to the React Native package (metro.config.js), and
// so does tsconfig's `paths` — except for a few types the native package
// does not re-export, which live in @assistant-ui/core and are declared
// here. Types only; nothing runs.
import type {
  DictationAdapter as CoreDictationAdapter,
  MessageTiming as CoreMessageTiming,
  Unstable_DirectiveFormatter as CoreDirectiveFormatter,
  Unstable_DirectiveSegment as CoreDirectiveSegment,
  Unstable_TriggerItem as CoreTriggerItem,
} from "@assistant-ui/core";

declare module "@assistant-ui/react-native" {
  export type DictationAdapter = CoreDictationAdapter;
  export type MessageTiming = CoreMessageTiming;
  export type Unstable_DirectiveFormatter = CoreDirectiveFormatter;
  export type Unstable_DirectiveSegment = CoreDirectiveSegment;
  export type Unstable_TriggerItem = CoreTriggerItem;
}
