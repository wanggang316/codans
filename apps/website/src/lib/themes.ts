// The themes in the Themes wall: six columns of three. Names are the Ghostty theme names.
export interface ThemeTile {
  shot: string;
  name: string;
}

export const THEME_COLUMNS: ThemeTile[][] = [
  [
    { shot: "theme-dracula", name: "Dracula" },
    { shot: "theme-github-dark", name: "GitHub Dark Default" },
    { shot: "theme-mocha", name: "Catppuccin Mocha" },
  ],
  [
    { shot: "theme-latte", name: "Catppuccin Latte" },
    { shot: "theme-monokai", name: "Monokai Pro" },
    { shot: "theme-night-owl", name: "Night Owl" },
  ],
  [
    { shot: "theme-tokyonight", name: "TokyoNight Storm" },
    { shot: "theme-github-light", name: "GitHub Light Default" },
    { shot: "theme-solarized", name: "Solarized Dark Patched" },
  ],
  [
    { shot: "theme-gruvbox", name: "Gruvbox Dark" },
    { shot: "theme-kanagawa", name: "Kanagawa Wave" },
    { shot: "theme-gruvbox-light", name: "Gruvbox Light" },
  ],
  [
    { shot: "theme-nord", name: "Nord" },
    { shot: "theme-one-dark", name: "Atom One Dark" },
    { shot: "theme-rosepine", name: "Rose Pine" },
  ],
  [
    { shot: "theme-rosepine-dawn", name: "Rose Pine Dawn" },
    { shot: "theme-everforest", name: "Everforest Dark Hard" },
    { shot: "theme-ayu", name: "Ayu Mirage" },
  ],
];
