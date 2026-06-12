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
        // The single accent — GitHub Primer functional blue, matching the
        // Codans app icon's blue block mark. Calm on a near-black surface:
        // it reads as a developer-tool accent, not an AI glow.
        // `acc-500` (#1F6FEB) is GitHub's dark-mode primary-button blue;
        // `acc-300` (#58A6FF) is its accent-text blue for inline marks.
        acc: {
          50: "#CAE8FF",
          100: "#A5D6FF",
          200: "#79C0FF",
          300: "#58A6FF",
          400: "#388BFD",
          500: "#1F6FEB",
          600: "#1158C7",
          700: "#0D419D",
          800: "#0C2D6B",
          900: "#051D4D",
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
        glow: "0 8px 30px -10px rgba(31, 111, 235, 0.45)",
        "glow-soft": "0 0 60px -22px rgba(31, 111, 235, 0.16)",
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
