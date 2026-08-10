// Verified against Pi 0.84.1, which exports ToolExecutionComponent with a render()
// method and stores rendered image children on the row. installCalmToolRowLayout()
// probes that exact seam and throws if it is missing; fm-calm.ts catches that and
// skips only this adapter with a diagnostic instead of blocking Calm or Pi.
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmPresentationHides } from "./fm-calm-visibility.ts";

type ToolExecutionComponentConstructor = typeof PiCodingAgent.ToolExecutionComponent;
type ToolExecutionComponentInstance = InstanceType<ToolExecutionComponentConstructor>;
type RenderComponent = {
  render(width: number): string[];
};
type ToolExecutionPresentationState = {
  imageComponents?: RenderComponent[];
  imageSpacers?: RenderComponent[];
};
type CalmToolRowLayoutPatch = {
  hidesToolRow: () => boolean;
  warnedMissingImageState: boolean;
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_TOOL_ROW_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-tool-row-layout:pi-0.84.1",
);

function renderImagesOnly(
  state: ToolExecutionPresentationState,
  width: number,
  patch: CalmToolRowLayoutPatch,
): string[] {
  const images = state.imageComponents;
  if (!Array.isArray(images)) {
    if (!patch.warnedMissingImageState) {
      patch.warnedMissingImageState = true;
      console.error(
        "Firstmate Calm: ToolExecutionComponent image state unavailable; hiding tool row without image parity.",
      );
    }
    return [];
  }
  if (images.length === 0) return [];

  const spacers = Array.isArray(state.imageSpacers) ? state.imageSpacers : [];
  const lines: string[] = [];
  for (let index = 0; index < images.length; index += 1) {
    const spacer = spacers[index];
    if (spacer) lines.push(...spacer.render(width));
    lines.push(...images[index].render(width));
  }
  return lines;
}

export function installCalmToolRowLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmToolRowLayoutPatch | undefined;
  };
  const hidesToolRow = (): boolean =>
    calmPresentationHides("assistant-tool-call") &&
    calmPresentationHides("tool-result");
  const installed = registry[CALM_TOOL_ROW_LAYOUT_PATCH];
  if (installed) {
    installed.hidesToolRow = hidesToolRow;
    return;
  }

  const patch: CalmToolRowLayoutPatch = {
    hidesToolRow,
    warnedMissingImageState: false,
  };
  const ToolExecutionComponent = PiCodingAgent.ToolExecutionComponent;
  if (typeof ToolExecutionComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi ToolExecutionComponent");
  }
  if (!Object.prototype.hasOwnProperty.call(ToolExecutionComponent.prototype, "render")) {
    throw new Error("Firstmate Calm requires Pi ToolExecutionComponent.render");
  }
  const originalRender = ToolExecutionComponent.prototype.render;
  if (typeof originalRender !== "function") {
    throw new Error("Firstmate Calm requires Pi ToolExecutionComponent.render");
  }

  ToolExecutionComponent.prototype.render = function (
    this: ToolExecutionComponentInstance,
    width: number,
    ...rest: unknown[]
  ): string[] {
    if (!patch.hidesToolRow()) {
      return (originalRender as (...args: unknown[]) => string[]).call(
        this,
        width,
        ...rest,
      );
    }
    return renderImagesOnly(this as unknown as ToolExecutionPresentationState, width, patch);
  };

  registry[CALM_TOOL_ROW_LAYOUT_PATCH] = patch;
}
