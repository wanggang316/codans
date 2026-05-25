/**
 * Editor app icons rendered as small rounded-square tiles, matching the
 * appearance of a macOS dock / toolbar app icon at toolbar size. Each
 * entry pairs a brand background color with a recognizable silhouette.
 *
 * Cursor / Xcode / Sublime Text paths are sourced from Simple Icons (CC0)
 * and inlined with their official brand colors. VS Code and Zed are
 * authored locally — Simple Icons does not host either today — as
 * minimal stand-ins (angle brackets / stylized Z) in their brand colors.
 * Finder is a generic folder mark on a Finder-blue tile.
 *
 * The component always renders in its brand colors (no currentColor
 * tinting), mirroring SwiftUI's `Image(nsImage:).renderingMode(.original)`
 * on `AppIconImage`.
 */

import { ReactNode } from "react";

interface Editor {
  /** Brand background tile color. */
  bg: string;
  /** Inner SVG content drawn over the tile (24×24 viewBox). */
  content: ReactNode;
}

const W = "#FFFFFF";

const EDITORS: Record<string, Editor> = {
  vscode: {
    bg: "#007ACC",
    content: (
      <path
        d="M8.5 7L4 12L8.5 17M15.5 7L20 12L15.5 17"
        stroke={W}
        strokeWidth="2.4"
        strokeLinecap="round"
        strokeLinejoin="round"
        fill="none"
      />
    ),
  },
  cursor: {
    bg: "#0E0E10",
    content: (
      <path
        fill={W}
        d="M11.503 4.131L4.891 7.678a.84.84 0 00-.42.726v8.188c0 .3.162.575.42.724l6.609 3.55a1 1 0 00.998 0l6.61-3.55a.84.84 0 00.42-.724V8.404a.84.84 0 00-.42-.726L12.497 4.131a1.01 1.01 0 00-.996 0M5.657 8.338h12.55c.263 0 .43.287.297.515L12.23 18.918c-.062.107-.229.064-.229-.06v-6.523a.59.59 0 00-.295-.51l-6.11-3.257c-.109-.063-.064-.23.061-.23"
      />
    ),
  },
  zed: {
    bg: "#084CCC",
    content: (
      <g fill="none" stroke={W} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M7 7h10L7 17h10" />
      </g>
    ),
  },
  xcode: {
    bg: "#147EFB",
    content: (
      // Compressed Xcode hammer/wrench silhouette in white. Simplified
      // from the Simple Icons path; the 24x24 viewbox is shrunk to
      // 4..20 to leave padding inside the tile.
      <g transform="translate(4 4) scale(0.67)">
        <path
          fill={W}
          d="M19.06 5.33c.45-.19.78-.26 1.1-.19.51.13.77.52.97.71.19.39.9.78 1.22.84.26.07.71-.65 1.03-1.29.32-.58.51-1.36.45-1.55-.07-.19-.97-.58-1.16-.58-.13 0-.39.13-.84.07-.45-.07-.9-.58-1.16-.97-.45-.65-1.1-1.03-1.68-1.36-.65-.32-1.36-.52-2.07-.65-1.03-.26-2.07-.45-3.1-.32-.58.06-1.29.13-1.81.32-.06 0-.19.19-.06.19s.58.07.58.07-.58.13-.58.26c0 .13.07.13.13.13s1.48-.07 2.07 0c.65.13 1.36.45 1.81 1.23.77 1.42.45 2.77.26 3.23-.97 2.13-8.65 15.23-9.03 16.13-.39.9-.52 1.48.58 2.07s1.68.32 2-.06c.39-.52 7.04-17.17 9.3-18.26z"
        />
      </g>
    ),
  },
  sublime: {
    bg: "#272822",
    content: (
      <g transform="translate(2 2) scale(0.83)">
        <path
          fill="#FF9800"
          d="M20.95.004a.397.397 0 00-.18.017L3.225 5.585c-.175.055-.323.214-.402.398a.42.42 0 00-.06.22v5.726a.42.42 0 00.06.22c.079.183.227.341.402.397l7.454 2.364-7.454 2.363c-.255.08-.463.374-.463.655v5.688c0 .282.208.444.463.363l17.55-5.565c.237-.075.426-.336.452-.6.003-.022.013-.04.013-.065V12.06c0-.281-.208-.575-.463-.656L13.4 9.065l7.375-2.339c.255-.08.462-.375.462-.656V.384c0-.211-.117-.355-.283-.38z"
        />
      </g>
    ),
  },
  finder: {
    bg: "#2A8EF7",
    content: (
      <g fill={W}>
        <circle cx="9" cy="10" r="1.2" />
        <circle cx="15" cy="10" r="1.2" />
        <path
          d="M7.5 14c1 2 3 3 4.5 3s3.5-1 4.5-3"
          stroke={W}
          strokeWidth="1.6"
          fill="none"
          strokeLinecap="round"
        />
      </g>
    ),
  },
};

/**
 * Renders an editor app icon as a colored rounded tile.
 */
export function EditorIcon({
  id,
  size = 14,
  className = "",
}: {
  id: string;
  size?: number;
  className?: string;
}) {
  const e = EDITORS[id];
  if (!e) {
    return (
      <span
        className={`inline-grid h-[${size}px] w-[${size}px] place-items-center rounded-[3px] bg-ink-dim/50 ${className}`}
        style={{ width: size, height: size }}
      />
    );
  }
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      aria-hidden
      className={`shrink-0 ${className}`}
    >
      <rect width="24" height="24" rx="5" fill={e.bg} />
      {e.content}
    </svg>
  );
}
