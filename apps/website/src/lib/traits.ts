// The product traits that take turns in the hero lede. The label of each trait is in the
// dictionaries; this file has the color and the icon (24 x 24, stroked).
export interface TraitStyle {
  color: string;
  icon: string;
}

export const TRAIT_STYLES: Record<string, TraitStyle> = {
  performance: { color: "#ff9f0a", icon: '<path d="M13 2 3 14h9l-1 8 10-12h-9l1-8z" />' },
  modern: {
    color: "#ff375f",
    icon: '<path d="M10 4c.6 4.6 3.4 7.4 8 8-4.6.6-7.4 3.4-8 8-.6-4.6-3.4-7.4-8-8 4.6-.6 7.4-3.4 8-8zM19 2v4M17 4h4" />',
  },
  // The worktree symbol of the app: three points with dotted lines between them.
  parallel: {
    color: "#5b7cfa",
    icon: '<g fill="currentColor" stroke="none"><circle cx="12" cy="5" r="2.6" /><circle cx="4.5" cy="18.5" r="2.6" /><circle cx="19.5" cy="18.5" r="2.6" /></g><path d="M12 5 4.5 18.5M4.5 18.5h15M19.5 18.5 12 5" pathLength="12" stroke-dasharray="0 1" stroke-width="1.9" />',
  },
  native: {
    color: "#d946ef",
    icon: '<rect x="4" y="5" width="16" height="11" rx="2" /><path d="M2 20h20" />',
  },
  open: {
    color: "#34c759",
    icon: '<rect x="4" y="11" width="16" height="10" rx="2" /><path d="M8 11V7a4 4 0 0 1 7.6-1.8" />',
  },
  scriptable: { color: "#14b8a6", icon: '<path d="m5 8 4 4-4 4M12 17h7" />' },
};
