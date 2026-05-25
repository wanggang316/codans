/**
 * Inline SVG icons for the app shell. Octicons-style git glyphs (re-authored,
 * MIT-spirited) plus minimal SF Symbol look-alikes redrawn from scratch — we
 * never copy proprietary symbol paths, only the visual idea.
 */
import { SVGProps } from "react";

type Props = SVGProps<SVGSVGElement> & { size?: number };

function Svg({ size = 16, children, ...rest }: Props & { children: React.ReactNode }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="currentColor"
      xmlns="http://www.w3.org/2000/svg"
      {...rest}
    >
      {children}
    </svg>
  );
}

// ─── chrome ──────────────────────────────────────────────────────────────

export const ChevronRight = (p: Props) => (
  <Svg {...p}>
    <path d="M6 4l4 4-4 4" stroke="currentColor" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round" />
  </Svg>
);

export const ChevronDown = (p: Props) => (
  <Svg {...p}>
    <path d="M4 6l4 4 4-4" stroke="currentColor" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round" />
  </Svg>
);

export const Plus = (p: Props) => (
  <Svg {...p}>
    <path d="M8 3v10M3 8h10" stroke="currentColor" strokeWidth="1.6" fill="none" strokeLinecap="round" />
  </Svg>
);

export const Ellipsis = (p: Props) => (
  <Svg {...p}>
    <circle cx="3.5" cy="8" r="1.2" />
    <circle cx="8" cy="8" r="1.2" />
    <circle cx="12.5" cy="8" r="1.2" />
  </Svg>
);

export const Search = (p: Props) => (
  <Svg {...p}>
    <circle cx="7" cy="7" r="4" fill="none" stroke="currentColor" strokeWidth="1.4" />
    <path d="M10 10l3 3" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
  </Svg>
);

export const Gear = (p: Props) => (
  <Svg {...p}>
    <circle cx="8" cy="8" r="2" fill="none" stroke="currentColor" strokeWidth="1.4" />
    <path
      d="M8 1.5v2M8 12.5v2M3.5 8h-2M14.5 8h-2M4.5 4.5L3 3M13 13l-1.5-1.5M4.5 11.5L3 13M13 3l-1.5 1.5"
      stroke="currentColor"
      strokeWidth="1.4"
      strokeLinecap="round"
    />
  </Svg>
);

export const Book = (p: Props) => (
  <Svg {...p}>
    <path
      d="M2.5 3a.5.5 0 01.5-.5h3.5A2.5 2.5 0 019 5v8a.5.5 0 01-.5.5H3.5a1 1 0 01-1-1V3z"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.2"
    />
    <path
      d="M13.5 3a.5.5 0 00-.5-.5H9.5A2.5 2.5 0 007 5v8a.5.5 0 00.5.5h5a1 1 0 001-1V3z"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.2"
    />
  </Svg>
);

export const ArrowUpRight = (p: Props) => (
  <Svg {...p}>
    <path d="M5 11l6-6M6 5h5v5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" fill="none" />
  </Svg>
);

export const CaretDown = (p: Props) => (
  <Svg {...p}>
    <path d="M4 6l4 4 4-4" fill="currentColor" />
  </Svg>
);

// ─── notifications ───────────────────────────────────────────────────────

export const Bell = (p: Props) => (
  <Svg {...p}>
    <path
      d="M8 1.5c-2.2 0-4 1.8-4 4v2.6L2.7 10c-.2.3 0 .8.4.8h9.8c.4 0 .6-.5.4-.8L12 8.1V5.5c0-2.2-1.8-4-4-4z"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.2"
      strokeLinejoin="round"
    />
    <path d="M6.4 12.5a1.6 1.6 0 003.2 0" stroke="currentColor" strokeWidth="1.2" fill="none" strokeLinecap="round" />
  </Svg>
);

export const BellFill = (p: Props) => (
  <Svg {...p}>
    <path d="M8 1.5c-2.2 0-4 1.8-4 4v2.6L2.7 10c-.2.3 0 .8.4.8h9.8c.4 0 .6-.5.4-.8L12 8.1V5.5c0-2.2-1.8-4-4-4z" />
    <path d="M6.4 12.5a1.6 1.6 0 003.2 0" stroke="currentColor" strokeWidth="1.2" fill="none" strokeLinecap="round" />
  </Svg>
);

// ─── status states ───────────────────────────────────────────────────────

export const CheckCircleFill = (p: Props) => (
  <Svg {...p}>
    <circle cx="8" cy="8" r="6.5" />
    <path d="M5 8.2L7.2 10.4 11 6.6" stroke="#0a0a0c" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round" />
  </Svg>
);

export const XCircleFill = (p: Props) => (
  <Svg {...p}>
    <circle cx="8" cy="8" r="6.5" />
    <path d="M5.5 5.5l5 5M10.5 5.5l-5 5" stroke="#0a0a0c" strokeWidth="1.6" strokeLinecap="round" />
  </Svg>
);

export const ClockCircleFill = (p: Props) => (
  <Svg {...p}>
    <circle cx="8" cy="8" r="6.5" />
    <path d="M8 4.5V8l2.2 1.4" stroke="#0a0a0c" strokeWidth="1.4" strokeLinecap="round" fill="none" />
  </Svg>
);

export const CircleDashed = (p: Props) => (
  <Svg {...p}>
    <circle
      cx="8"
      cy="8"
      r="6"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.3"
      strokeDasharray="2 2"
    />
  </Svg>
);

export const PauseFill = (p: Props) => (
  <Svg {...p}>
    <rect x="4" y="3.5" width="2.6" height="9" rx="0.6" />
    <rect x="9.4" y="3.5" width="2.6" height="9" rx="0.6" />
  </Svg>
);

export const PinFill = (p: Props) => (
  <Svg {...p}>
    <path d="M9.2 1.5l5.3 5.3-1.4 1.4-1.4-.4-3.5 3.5.4 1.4L7.2 14l-2.8-2.8 1.4-1.4 1.4.4L10.7 6.7l-.4-1.4L11.7 4l-2.5-2.5z" />
  </Svg>
);

export const Folder = (p: Props) => (
  <Svg {...p}>
    <path
      d="M2 4a1 1 0 011-1h3l1.5 1.5H13a1 1 0 011 1v6a1 1 0 01-1 1H3a1 1 0 01-1-1V4z"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.3"
      strokeLinejoin="round"
    />
  </Svg>
);

export const StarFill = (p: Props) => (
  <Svg {...p}>
    <path d="M8 1.5l1.85 4.05 4.4.5-3.27 3.02.92 4.33L8 11.3 4.1 13.4l.92-4.33L1.75 6.05l4.4-.5L8 1.5z" />
  </Svg>
);

// ─── git glyphs (Octicons-flavored, redrawn) ─────────────────────────────

/** git-branch — three nodes connected by a curved + straight line. */
export const GitBranch = (p: Props) => (
  <Svg {...p}>
    <circle cx="4" cy="3.5" r="1.6" fill="none" stroke="currentColor" strokeWidth="1.4" />
    <circle cx="4" cy="12.5" r="1.6" fill="none" stroke="currentColor" strokeWidth="1.4" />
    <circle cx="12" cy="5.5" r="1.6" fill="none" stroke="currentColor" strokeWidth="1.4" />
    <path d="M4 5.1v5.8" stroke="currentColor" strokeWidth="1.4" />
    <path d="M4 6.5c0 2.5 2 4 4 4h2.5" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
  </Svg>
);

/** git-pull-request — branch with an arrow head landing on the right node. */
export const GitPullRequest = (p: Props) => (
  <Svg {...p}>
    <circle cx="4" cy="3.5" r="1.6" fill="none" stroke="currentColor" strokeWidth="1.4" />
    <circle cx="4" cy="12.5" r="1.6" fill="none" stroke="currentColor" strokeWidth="1.4" />
    <circle cx="12" cy="12.5" r="1.6" fill="none" stroke="currentColor" strokeWidth="1.4" />
    <path d="M4 5.1v5.8" stroke="currentColor" strokeWidth="1.4" />
    <path d="M12 3v8" stroke="currentColor" strokeWidth="1.4" />
    <path d="M10 5l2-2 2 2" stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round" strokeLinejoin="round" />
  </Svg>
);

/** git-pull-request-draft — same geometry, dashed strokes for the "draft" feel. */
export const GitPullRequestDraft = (p: Props) => (
  <Svg {...p}>
    <circle cx="4" cy="3.5" r="1.6" fill="none" stroke="currentColor" strokeWidth="1.4" />
    <circle cx="4" cy="12.5" r="1.6" fill="none" stroke="currentColor" strokeWidth="1.4" />
    <circle cx="12" cy="12.5" r="1.6" fill="none" stroke="currentColor" strokeWidth="1.4" strokeDasharray="1.5 1.5" />
    <path d="M4 5.1v5.8" stroke="currentColor" strokeWidth="1.4" />
    <path d="M12 4v6.5" stroke="currentColor" strokeWidth="1.4" strokeDasharray="1.5 1.5" />
  </Svg>
);

/** git-pull-request-closed — branch with an X over the right node. */
export const GitPullRequestClosed = (p: Props) => (
  <Svg {...p}>
    <circle cx="4" cy="3.5" r="1.6" fill="none" stroke="currentColor" strokeWidth="1.4" />
    <circle cx="4" cy="12.5" r="1.6" fill="none" stroke="currentColor" strokeWidth="1.4" />
    <circle cx="12" cy="12.5" r="1.6" fill="none" stroke="currentColor" strokeWidth="1.4" />
    <path d="M4 5.1v5.8" stroke="currentColor" strokeWidth="1.4" />
    <path d="M10 3l4 4M14 3l-4 4" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
  </Svg>
);

/** git-merge — branch curving up + landing in the right node. */
export const GitMerge = (p: Props) => (
  <Svg {...p}>
    <circle cx="4" cy="3.5" r="1.6" fill="none" stroke="currentColor" strokeWidth="1.4" />
    <circle cx="4" cy="12.5" r="1.6" fill="none" stroke="currentColor" strokeWidth="1.4" />
    <circle cx="12" cy="5.5" r="1.6" fill="none" stroke="currentColor" strokeWidth="1.4" />
    <path d="M4 5.1v5.8" stroke="currentColor" strokeWidth="1.4" />
    <path d="M4 7c0 3 2 5 6 5" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
  </Svg>
);

/** Three connected nodes — the SwiftUI app uses this for the header branch label. */
export const ConnectedNodes = (p: Props) => (
  <Svg {...p}>
    <circle cx="3.5" cy="3.5" r="1.3" fill="currentColor" />
    <circle cx="3.5" cy="12.5" r="1.3" fill="currentColor" />
    <circle cx="12.5" cy="8" r="1.3" fill="currentColor" />
    <path
      d="M3.5 4.8c0 3.6 4 4.3 6 4.3M3.5 11.2c0-3.6 4-4.3 6-4.3"
      stroke="currentColor"
      strokeWidth="1.1"
      fill="none"
      strokeLinecap="round"
    />
  </Svg>
);

// ─── agent marks (letterforms — placeholder until brand SVGs ship) ───────

/**
 * Letter-based agent marks. The real app embeds brand SVG assets that we do
 * not own; we substitute simple geometric letterforms so the row layout reads
 * the same without copying proprietary marks. The host site can swap these
 * for licensed glyphs without touching layout.
 */

export const AgentClaude = (p: Props) => (
  <Svg {...p} viewBox="0 0 24 24">
    <circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" strokeWidth="1.6" />
    <path
      d="M9.5 8.5c-1.5 0-2.5 1.4-2.5 3.5s1 3.5 2.5 3.5c1.1 0 1.9-.5 2.3-1.5"
      stroke="currentColor"
      strokeWidth="1.6"
      fill="none"
      strokeLinecap="round"
    />
  </Svg>
);

export const AgentCodex = (p: Props) => (
  <Svg {...p} viewBox="0 0 24 24">
    <path
      d="M12 3l8 4.5v9L12 21l-8-4.5v-9z"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinejoin="round"
    />
    <path
      d="M8 9.5l4 2.5 4-2.5M12 12v6"
      stroke="currentColor"
      strokeWidth="1.5"
      fill="none"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  </Svg>
);

export const AgentPi = (p: Props) => (
  <Svg {...p} viewBox="0 0 24 24">
    <circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" strokeWidth="1.6" />
    <path
      d="M7.5 9h9M9.5 9v6.5c0 .8.4 1.3 1.2 1.3M14.5 9v8"
      stroke="currentColor"
      strokeWidth="1.6"
      fill="none"
      strokeLinecap="round"
    />
  </Svg>
);

export const AgentOpenCode = (p: Props) => (
  <Svg {...p} viewBox="0 0 24 24">
    <rect x="3.5" y="3.5" width="17" height="17" rx="3" fill="none" stroke="currentColor" strokeWidth="1.5" />
    <path d="M9 9l-3 3 3 3M15 9l3 3-3 3" stroke="currentColor" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round" />
  </Svg>
);

// ─── loading 3x3 grid ────────────────────────────────────────────────────

export function LoadingGrid({ size = 14, className = "" }: { size?: number; className?: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" className={className} fill="currentColor">
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
