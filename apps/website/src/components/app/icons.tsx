/**
 * Icon set for the marketing app shell.
 *
 * Three sources:
 *
 * 1. Real SVG assets sourced from the touch-code Mac app
 *    (`apps/mac/touch-code/App/Assets.xcassets/*.imageset/*.svg`) — copied
 *    verbatim to `public/icons/` and rendered via the CSS-mask trick so
 *    they inherit `currentColor`. These cover the git glyphs (Octicons),
 *    the agent brand marks (claude-code / codex / pi / opencode), and
 *    GitHub.
 *
 * 2. `lucide-react` — the open-source icon set that mirrors the visual
 *    language of Apple's SF Symbols. Used for every system glyph the
 *    Mac app loads via `Image(systemName: …)` (bell, folder, star,
 *    chevron, plus, ellipsis, search, gear, book, pause, pin, sparkles,
 *    refresh, sort, workflow, play).
 *
 * 3. Hand-drawn filled-disc rollup glyphs (passing / failing / pending
 *    check overlays) — these are two-tone "filled disc + cutout
 *    symbol" composites that lucide doesn't ship, so we draw the four
 *    we need ourselves.
 */
import type { LucideIcon } from "lucide-react";
import {
  ArrowUpDown,
  ArrowUpRight,
  Bell as LBell,
  BookOpen as LBookOpen,
  ChevronDown as LChevronDown,
  ChevronRight as LChevronRight,
  CircleDashed as LCircleDashed,
  Folder as LFolder,
  MoreHorizontal,
  Pause as LPause,
  Pin as LPin,
  Play as LPlay,
  Plus as LPlus,
  RefreshCw,
  Search as LSearch,
  Settings as LSettings,
  Sparkles as LSparkles,
  Star as LStar,
  Workflow as LWorkflow,
} from "lucide-react";

interface SizeProps {
  size?: number;
  className?: string;
}

// ─── mask-based icon — currentColor-tintable from any SVG asset ─────────

/**
 * Renders an SVG asset (referenced by URL) as a colored shape using
 * `mask-image: url(...)`. The element's `background-color: currentColor`
 * makes the icon pick up whatever text color its parent uses, regardless
 * of the SVG's internal `fill="black"` / `fill="#09090b"`.
 */
function MaskIcon({ src, size = 16, className = "" }: { src: string } & SizeProps) {
  return (
    <span
      aria-hidden
      className={`inline-block shrink-0 ${className}`}
      style={{
        width: size,
        height: size,
        backgroundColor: "currentColor",
        maskImage: `url(${src})`,
        WebkitMaskImage: `url(${src})`,
        maskSize: "contain",
        WebkitMaskSize: "contain",
        maskRepeat: "no-repeat",
        WebkitMaskRepeat: "no-repeat",
        maskPosition: "center",
        WebkitMaskPosition: "center",
      }}
    />
  );
}

// ─── git glyphs (Octicons; real asset files from apps/mac) ───────────────

export const GitBranch = (p: SizeProps) => <MaskIcon src="/icons/git-branch.svg" {...p} />;
export const GitMerge = (p: SizeProps) => <MaskIcon src="/icons/git-merge.svg" {...p} />;
export const GitPullRequest = (p: SizeProps) => (
  <MaskIcon src="/icons/git-pull-request.svg" {...p} />
);
export const GitPullRequestDraft = (p: SizeProps) => (
  <MaskIcon src="/icons/git-pull-request-draft.svg" {...p} />
);
export const GitPullRequestClosed = (p: SizeProps) => (
  <MaskIcon src="/icons/git-pull-request-closed.svg" {...p} />
);
export const GitHubMark = (p: SizeProps) => <MaskIcon src="/icons/github.svg" {...p} />;

// ─── agent marks (brand SVGs from apps/mac) ──────────────────────────────

export const AgentClaude = (p: SizeProps) => <MaskIcon src="/icons/claude-code.svg" {...p} />;
export const AgentCodex = (p: SizeProps) => <MaskIcon src="/icons/codex.svg" {...p} />;
export const AgentPi = (p: SizeProps) => <MaskIcon src="/icons/pi.svg" {...p} />;
export const AgentOpenCode = (p: SizeProps) => <MaskIcon src="/icons/opencode.svg" {...p} />;

// ─── SF Symbol replacements (lucide-react) ───────────────────────────────

/**
 * A lucide wrapper that lets us:
 * - default the size + stroke weight to look closer to SF Symbol density
 * - flip to a filled variant when we want the SwiftUI `.fill` look
 */
function makeLucide(C: LucideIcon, defaults: { strokeWidth?: number; filled?: boolean } = {}) {
  return function Icon({ size = 16, className = "" }: SizeProps) {
    const { strokeWidth = 1.8, filled = false } = defaults;
    return (
      <C
        size={size}
        strokeWidth={strokeWidth}
        fill={filled ? "currentColor" : "none"}
        className={className}
      />
    );
  };
}

export const ChevronDown = makeLucide(LChevronDown, { strokeWidth: 2 });
export const ChevronRight = makeLucide(LChevronRight, { strokeWidth: 2 });
export const Plus = makeLucide(LPlus, { strokeWidth: 2.2 });
export const Ellipsis = makeLucide(MoreHorizontal, { strokeWidth: 2.2 });
export const Search = makeLucide(LSearch, { strokeWidth: 2 });
export const Gear = makeLucide(LSettings, { strokeWidth: 1.8 });
export const Book = makeLucide(LBookOpen, { strokeWidth: 1.8 });
export const Folder = makeLucide(LFolder, { strokeWidth: 1.8 });
export const CircleDashed = makeLucide(LCircleDashed, { strokeWidth: 1.6 });

// "Filled" SF Symbol variants — lucide icons with both stroke + fill set
// to currentColor render as solid shapes the same way SwiftUI's `.fill`
// modifier reads.
export const Bell = makeLucide(LBell, { strokeWidth: 1.8 });
export const BellFill = makeLucide(LBell, { strokeWidth: 1.6, filled: true });
export const StarFill = makeLucide(LStar, { strokeWidth: 1.4, filled: true });
export const PinFill = makeLucide(LPin, { strokeWidth: 1.4, filled: true });
export const PauseFill = makeLucide(LPause, { strokeWidth: 1.4, filled: true });

export const PlayFill = makeLucide(LPlay, { strokeWidth: 1.4, filled: true });
export const Sparkles = makeLucide(LSparkles, { strokeWidth: 1.6 });
export const SparklesFill = makeLucide(LSparkles, { strokeWidth: 1.4, filled: true });
export const SortIcon = makeLucide(ArrowUpDown, { strokeWidth: 1.8 });
export const Refresh = makeLucide(RefreshCw, { strokeWidth: 1.8 });
export const Workflow = makeLucide(LWorkflow, { strokeWidth: 1.8 });

// "Arrow up forward.app" → lucide ArrowUpRight, used by the Open-in button.
export { ArrowUpRight };

// CaretDown — small filled down chevron used by split-button menus.
// Render lucide ChevronDown with a heavier fill so it reads as a caret,
// not a delicate stroke.
export function CaretDown({ size = 10, className = "" }: SizeProps) {
  return (
    <svg
      aria-hidden
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="currentColor"
      className={className}
    >
      <path d="M4.5 6h7L8 10.5 4.5 6Z" />
    </svg>
  );
}

// ─── hand-drawn filled-disc rollup glyphs ────────────────────────────────
//
// SwiftUI composes these with `symbolRenderingMode(.palette)` and two
// foreground styles (windowBackground + state color) so the inner glyph
// reads as a cutout from the disc. Lucide doesn't ship this composite
// directly, so we author it with two paths: a filled circle plus an
// inner symbol stroked in the panel background color so it punches out.

const PANEL = "#0a0a0c";

export function CheckCircleFill({ size = 12, className = "" }: SizeProps) {
  return (
    <svg
      aria-hidden
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="currentColor"
      className={className}
    >
      <circle cx="8" cy="8" r="7" />
      <path
        d="M4.6 8.2 7.0 10.6 11.4 5.6"
        stroke={PANEL}
        strokeWidth="1.8"
        fill="none"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

export function XCircleFill({ size = 12, className = "" }: SizeProps) {
  return (
    <svg
      aria-hidden
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="currentColor"
      className={className}
    >
      <circle cx="8" cy="8" r="7" />
      <path
        d="M5 5 11 11 M11 5 5 11"
        stroke={PANEL}
        strokeWidth="1.8"
        strokeLinecap="round"
      />
    </svg>
  );
}

export function ClockCircleFill({ size = 12, className = "" }: SizeProps) {
  return (
    <svg
      aria-hidden
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="currentColor"
      className={className}
    >
      <circle cx="8" cy="8" r="7" />
      <path
        d="M8 4.5V8l2.4 1.6"
        stroke={PANEL}
        strokeWidth="1.6"
        strokeLinecap="round"
        fill="none"
      />
    </svg>
  );
}

// ─── loading 3x3 grid (matches LoadingGridIcon in ActiveAgentsRowView) ───

export function LoadingGrid({ size = 14, className = "" }: SizeProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      className={className}
      fill="currentColor"
      aria-hidden
    >
      {[0, 1, 2].flatMap((row) =>
        [0, 1, 2].map((col) => (
          <rect
            key={`${row}-${col}`}
            x={2 + col * 8}
            y={2 + row * 8}
            width="6"
            height="6"
            rx="0.6"
            style={{
              animation: `loading-grid 3s linear ${0.2 + col * 0.2 + row * 0.6}s infinite`,
            }}
          />
        )),
      )}
      <style>{`
        @keyframes loading-grid {
          0%   { opacity: 1; }
          90%  { opacity: 0; }
          100% { opacity: 0; }
        }
      `}</style>
    </svg>
  );
}
