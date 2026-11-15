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
  parallel: {
    color: "#5b7cfa",
    icon: '<path d="M6 3v12" /><circle cx="18" cy="6" r="3" /><circle cx="6" cy="18" r="3" /><path d="M18 9a9 9 0 0 1-9 9" />',
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
