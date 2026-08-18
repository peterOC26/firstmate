// Verified against Pi 0.84.1, which exports ToolExecutionComponent with a render()
// method and stores rendered image children in its imageComponents and imageSpacers
// fields. installCalmToolRowLayout() probes both seams - the render method and a real
// probe instance's image state - and throws if either is missing; fm-calm.ts catches
// that and skips only this adapter with a diagnostic instead of blocking Calm or Pi.
// Failing closed at install keeps a renamed image seam from silently dropping image
// output row by row, and keeps every diagnostic off Pi's render path.
// This adapter is screen-only: Pi builds /export and /share output from tool
// definitions rather than from these rows, so it reads the Calm policy without the
// stock-export escape hatch the definition wrappers need.
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmScreenPresentationHides } from "./fm-calm-visibility.ts";

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
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_TOOL_ROW_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-tool-row-layout:pi-0.84.1",
);

// Pi initializes the image children as instance fields in its constructor rather than
// on the prototype, so the only honest probe is a throwaway row. Two details keep that
// probe inert: a tool name no definition can match takes Pi's definition-free
// construction path, and Pi's constructor also paints an initial display through a
// theme that Pi initializes after it loads extensions, so the probe suppresses that one
// prototype method for the length of the construction and restores it immediately. The
// probed row is never attached to a container and is discarded here.
const CALM_TOOL_ROW_PROBE_NAME = "firstmate_calm_tool_row_probe";

function probeImageState(constructor: ToolExecutionComponentConstructor): void {
  const construct = constructor as unknown as new (...args: unknown[]) => unknown;
  const prototype = constructor.prototype as unknown as Record<string, unknown>;
  const originalUpdateDisplay = prototype.updateDisplay;
  const suppressesDisplay = typeof originalUpdateDisplay === "function";
  if (suppressesDisplay) prototype.updateDisplay = () => {};
  let probe: ToolExecutionPresentationState;
  try {
    probe = new construct(
      CALM_TOOL_ROW_PROBE_NAME,
      CALM_TOOL_ROW_PROBE_NAME,
      {},
      { showImages: false },
      undefined,
      undefined,
      process.cwd(),
    ) as ToolExecutionPresentationState;
  } finally {
    if (suppressesDisplay) prototype.updateDisplay = originalUpdateDisplay;
  }
  if (!Array.isArray(probe.imageComponents) || !Array.isArray(probe.imageSpacers)) {
    throw new Error("Firstmate Calm requires Pi ToolExecutionComponent image state");
  }
}

function renderImagesOnly(
  state: ToolExecutionPresentationState,
  width: number,
): string[] {
  const images = state.imageComponents;
  if (!Array.isArray(images) || images.length === 0) return [];

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
    calmScreenPresentationHides("assistant-tool-call") &&
    calmScreenPresentationHides("tool-result");
  const installed = registry[CALM_TOOL_ROW_LAYOUT_PATCH];
  if (installed) {
    installed.hidesToolRow = hidesToolRow;
    return;
  }

  const patch: CalmToolRowLayoutPatch = { hidesToolRow };
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
  probeImageState(ToolExecutionComponent);

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
    return renderImagesOnly(this as unknown as ToolExecutionPresentationState, width);
  };

  registry[CALM_TOOL_ROW_LAYOUT_PATCH] = patch;
}
