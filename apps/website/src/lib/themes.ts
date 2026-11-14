// The themes in the Themes wall: three rows of six. Names are the Ghostty theme names.
export interface ThemeTile {
  shot: string;
  name: string;
}

export const THEME_ROWS: ThemeTile[][] = [
  [
    { shot: "theme-dracula", name: "Dracula" },
    { shot: "theme-latte", name: "Catppuccin Latte" },
    { shot: "theme-tokyonight", name: "TokyoNight Storm" },
    { shot: "theme-gruvbox", name: "Gruvbox Dark" },
    { shot: "theme-nord", name: "Nord" },
    { shot: "theme-rosepine-dawn", name: "Rose Pine Dawn" },
  ],
  [
    { shot: "theme-github-dark", name: "GitHub Dark Default" },
    { shot: "theme-monokai", name: "Monokai Pro" },
    { shot: "theme-github-light", name: "GitHub Light Default" },
    { shot: "theme-kanagawa", name: "Kanagawa Wave" },
    { shot: "theme-one-dark", name: "Atom One Dark" },
    { shot: "theme-everforest", name: "Everforest Dark Hard" },
  ],
  [
    { shot: "theme-mocha", name: "Catppuccin Mocha" },
    { shot: "theme-gruvbox-light", name: "Gruvbox Light" },
    { shot: "theme-night-owl", name: "Night Owl" },
    { shot: "theme-solarized", name: "Solarized Dark Patched" },
    { shot: "theme-rosepine", name: "Rose Pine" },
    { shot: "theme-ayu", name: "Ayu Mirage" },
  ],
];
