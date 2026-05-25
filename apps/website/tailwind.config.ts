import type { Config } from "tailwindcss";

export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  darkMode: "class",
  theme: {
    extend: {
      colors: {
        bg: {
          DEFAULT: "#0A0A0B",
          elev: "#131315",
          card: "#16161A",
        },
        ink: {
          DEFAULT: "#E8E8EA",
          muted: "#8A8A92",
          dim: "#5A5A62",
        },
        line: {
          DEFAULT: "#1F1F22",
          strong: "#2A2A2F",
        },
        leaf: {
          50: "#E8F3C8",
          100: "#C5E075",
          300: "#A7C65C",
          500: "#83AD40",
          700: "#547B32",
          900: "#42692B",
        },
      },
      fontFamily: {
        sans: [
          "Inter",
          "ui-sans-serif",
          "system-ui",
          "-apple-system",
          "Segoe UI",
          "sans-serif",
        ],
        mono: [
          "JetBrains Mono",
          "ui-monospace",
          "SFMono-Regular",
          "Menlo",
          "monospace",
        ],
      },
      fontSize: {
        "display-1": ["clamp(2.75rem, 6vw, 5.25rem)", { lineHeight: "1.02", letterSpacing: "-0.04em" }],
        "display-2": ["clamp(2rem, 4vw, 3.5rem)", { lineHeight: "1.05", letterSpacing: "-0.03em" }],
      },
      boxShadow: {
        glow: "0 0 60px -10px rgba(167, 198, 92, 0.35)",
        "glow-soft": "0 0 80px -20px rgba(167, 198, 92, 0.18)",
        "window": "0 30px 80px -20px rgba(0,0,0,0.7), 0 0 0 1px rgba(255,255,255,0.06) inset",
      },
      backgroundImage: {
        "grid-faint":
          "linear-gradient(rgba(255,255,255,0.025) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.025) 1px, transparent 1px)",
      },
      keyframes: {
        blink: { "0%,49%": { opacity: "1" }, "50%,100%": { opacity: "0" } },
        scan: { "0%": { transform: "translateX(-100%)" }, "100%": { transform: "translateX(100%)" } },
        breathe: { "0%,100%": { opacity: "0.55" }, "50%": { opacity: "1" } },
      },
      animation: {
        blink: "blink 1.1s steps(1) infinite",
        scan: "scan 2.6s linear infinite",
        breathe: "breathe 3.2s ease-in-out infinite",
      },
    },
  },
  plugins: [],
} satisfies Config;
