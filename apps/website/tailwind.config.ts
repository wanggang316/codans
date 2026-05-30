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
        // The single accent — GitHub Primer functional green. Calmer and
        // less neon than WeChat green on a near-black surface, which is the
        // whole point: it reads as a developer-tool accent, not an AI glow.
        // `acc-500` (#238636) is GitHub's dark-mode primary-button green;
        // `acc-300` (#3FB950) is its success-text green for inline marks.
        acc: {
          50: "#DAFBE1",
          100: "#ACEEBB",
          200: "#6FDD8B",
          300: "#3FB950",
          400: "#2EA043",
          500: "#238636",
          600: "#1A7F37",
          700: "#116329",
          800: "#044F1E",
          900: "#003D16",
        },
      },
      fontFamily: {
        sans: [
          "Geist",
          "Inter",
          "ui-sans-serif",
          "system-ui",
          "-apple-system",
          "Segoe UI",
          "sans-serif",
        ],
        mono: [
          "JetBrains Mono",
          "Geist Mono",
          "ui-monospace",
          "SFMono-Regular",
          "Menlo",
          "monospace",
        ],
      },
      fontSize: {
        "display-1": ["clamp(2.75rem, 6vw, 5.25rem)", { lineHeight: "1.04", letterSpacing: "-0.04em" }],
        "display-2": ["clamp(2rem, 4vw, 3.25rem)", { lineHeight: "1.06", letterSpacing: "-0.03em" }],
      },
      boxShadow: {
        glow: "0 8px 30px -10px rgba(35, 134, 54, 0.45)",
        "glow-soft": "0 0 60px -22px rgba(35, 134, 54, 0.16)",
        window: "0 40px 90px -30px rgba(0,0,0,0.8), 0 0 0 1px rgba(255,255,255,0.05) inset",
      },
      backgroundImage: {
        "grid-faint":
          "linear-gradient(rgba(255,255,255,0.025) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.025) 1px, transparent 1px)",
      },
      keyframes: {
        blink: { "0%,49%": { opacity: "1" }, "50%,100%": { opacity: "0" } },
        breathe: { "0%,100%": { opacity: "0.55" }, "50%": { opacity: "1" } },
      },
      animation: {
        blink: "blink 1.1s steps(1) infinite",
        breathe: "breathe 3.2s ease-in-out infinite",
      },
    },
  },
  plugins: [],
} satisfies Config;
