// The product traits that take turns in the hero lede. The label of each trait is in the
// dictionaries; this file has the color and the icon (24 x 24, stroked).
export interface TraitStyle {
  color: string;
  icon: string;
}

export const TRAIT_STYLES: Record<string, TraitStyle> = {
  performance: { color: "#ff9f0a", icon: '<path d="M13 2 3 14h9l-1 8 10-12h-9l1-8z" />' },
  parallel: {
    color: "#5b7cfa",
    icon: '<rect x="3" y="4" width="18" height="16" rx="2" /><path d="M12 4v16" />',
  },
  native: {
    color: "#d946ef",
    icon: '<rect x="4" y="5" width="16" height="11" rx="2" /><path d="M2 20h20" />',
  },
  open: {
    color: "#34c759",
    icon: '<circle cx="6" cy="5" r="2.5" /><circle cx="18" cy="5" r="2.5" /><circle cx="12" cy="19" r="2.5" /><path d="M6 7.5V9a3 3 0 0 0 3 3h6a3 3 0 0 0 3-3V7.5M12 12v4.5" />',
  },
  scriptable: { color: "#14b8a6", icon: '<path d="m5 8 4 4-4 4M12 17h7" />' },
};
