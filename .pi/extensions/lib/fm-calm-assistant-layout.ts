// Verified against Pi 0.81.1, 0.82.0, 0.84.1, and 0.84.2, which export
// AssistantMessageComponent with an updateContent method whose later arguments this
// adapter forwards unchanged.
// installCalmAssistantLayout() probes that exact method and throws
// if it is missing; fm-calm.ts catches that and skips only this adapter with a diagnostic
// instead of blocking Calm or Pi.
// This layout removes collapsed thinking and the mid-turn assistant text blocks
// classified as "assistant-working-note" from a shallow presentation copy. The message
// itself, model context, session storage, and export rendering are never touched.
// ./fm-calm-visibility.ts owns which classes Calm hides.
// This adapter is screen-only: Pi builds /export and /share output from session entries
// and never from these rows, so it reads the Calm policy without the stock-export escape
// hatch the tool-definition wrappers and the synthetic entry renderer need.
import type { AssistantMessageComponent as PiAssistantMessageComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmScreenPresentationHides } from "./fm-calm-visibility.ts";

type AssistantMessage = Parameters<PiAssistantMessageComponent["updateContent"]>[0];

type AssistantMessagePresentationState = {
  hiddenThinkingLabel: string;
  hideThinkingBlock: boolean;
  lastMessage?: AssistantMessage;
};

type CalmAssistantLayoutPatch = {
  hidesThinking: () => boolean;
  hidesWorkingNote: () => boolean;
  hidesSyntheticToolChrome: () => boolean;
};

type JsonEnd = { lineOffset: number; endOffset: number } | undefined;

function findJsonEnd(value: string): JsonEnd {
  const first = value[0];
  if (first !== "{" && first !== "[") return undefined;
  let depth = 0;
  let quoted = false;
  let escaped = false;
  for (let characterOffset = 0; characterOffset < value.length; characterOffset += 1) {
    const character = value[characterOffset];
    if (quoted) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === '"') quoted = false;
      continue;
    }
    if (character === '"') {
      quoted = true;
      continue;
    }
    if (character === "{" || character === "[") depth += 1;
    else if (character === "}" || character === "]") {
      depth -= 1;
      if (depth === 0) {
        const linesBefore = value.slice(0, characterOffset + 1).split("\n").length - 1;
        return { lineOffset: linesBefore, endOffset: characterOffset + 1 };
      }
    }
  }
  return undefined;
}

function stripSyntheticToolChrome(text: string): string {
  const lines = text.split("\n");
  const kept: string[] = [];
  for (let index = 0; index < lines.length; index += 1) {
    const match = /^\s*⏳\s+\[[^\]\r\n]+\]\s*(.*)$/.exec(lines[index]);
    if (!match) {
      kept.push(lines[index]);
      continue;
    }
    const inlineArgument = match[1].trimStart();
    const argumentIsInline = inlineArgument.startsWith("{") || inlineArgument.startsWith("[");
    const nextLineArgument = lines.slice(index + 1).join("\n").trimStart();
    const argument = argumentIsInline
      ? [inlineArgument, ...lines.slice(index + 1)].join("\n")
      : nextLineArgument;
    if (argument.startsWith("{") || argument.startsWith("[")) {
      const end = findJsonEnd(argument);
      if (end) {
        try {
          JSON.parse(argument.slice(0, end.endOffset));
          index += end.lineOffset + (argumentIsInline ? 0 : 1);
        } catch {
          // A balanced non-JSON suffix is ordinary text, so leave it visible.
        }
      }
    }
  }
  return kept.join("\n");
}

// A mid-turn assistant message is one the model did not end its response with: Pi's
// agent loop runs its tool calls and then issues another assistant message. stopReason
// is intrinsic to each message and is already set while the message streams, so this
// layout never has to ask whether the turn ended. It stays "pending" until the tool
// call materializes, which is why a working note is briefly visible before it
// collapses; suppressing pending text would also stop a genuine reply from streaming.
function isMidTurnAssistantMessage(message: AssistantMessage): boolean {
  if (message.stopReason === "toolUse") return true;
  return (
    message.stopReason === "length" &&
    message.content.some((block) => block.type === "toolCall")
  );
}

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_ASSISTANT_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-assistant-layout:pi-0.81.1",
);

export function installCalmAssistantLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmAssistantLayoutPatch | undefined;
  };
  const hidesThinking = (): boolean => calmScreenPresentationHides("assistant-thinking");
  const hidesWorkingNote = (): boolean =>
    calmScreenPresentationHides("assistant-working-note");
  const hidesSyntheticToolChrome = (): boolean =>
    calmScreenPresentationHides("assistant-synthetic-tool-chrome");
  const installed = registry[CALM_ASSISTANT_LAYOUT_PATCH];
  if (installed) {
    installed.hidesThinking = hidesThinking;
    installed.hidesWorkingNote = hidesWorkingNote;
    installed.hidesSyntheticToolChrome = hidesSyntheticToolChrome;
    return;
  }

  const patch: CalmAssistantLayoutPatch = {
    hidesThinking,
    hidesWorkingNote,
    hidesSyntheticToolChrome,
  };
  const AssistantMessageComponent = PiCodingAgent.AssistantMessageComponent;
  if (typeof AssistantMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent");
  }
  const originalUpdateContent = AssistantMessageComponent.prototype.updateContent;
  if (typeof originalUpdateContent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent.updateContent");
  }

  AssistantMessageComponent.prototype.updateContent = function (
    message: AssistantMessage,
    ...rest: unknown[]
  ): void {
    const state = this as unknown as AssistantMessagePresentationState;
    const hideThinking =
      state.hiddenThinkingLabel === "" &&
      state.hideThinkingBlock &&
      patch.hidesThinking();
    const hideWorkingNote =
      patch.hidesWorkingNote() && isMidTurnAssistantMessage(message);
    const hideSyntheticToolChrome = patch.hidesSyntheticToolChrome();
    const presentationMessage =
      hideThinking || hideWorkingNote || hideSyntheticToolChrome
        ? {
            ...message,
            content: message.content.filter(
              (block) =>
                !(hideThinking && block.type === "thinking") &&
                !(hideWorkingNote && block.type === "text"),
            ).map((block) =>
              hideSyntheticToolChrome && block.type === "text"
                ? { ...block, text: stripSyntheticToolChrome(block.text) }
                : block,
            ),
          }
        : message;

    (originalUpdateContent as (...args: unknown[]) => void).call(
      this,
      presentationMessage,
      ...rest,
    );
    if (presentationMessage !== message) state.lastMessage = message;
  };

  registry[CALM_ASSISTANT_LAYOUT_PATCH] = patch;
}
