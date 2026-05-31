import i18n from "i18next";
import { initReactI18next } from "react-i18next";

import enLanding from "./locales/en/landing.json";
import zhLanding from "./locales/zh/landing.json";

export const SUPPORTED_LANGS = ["en", "zh"] as const;
export type Lang = (typeof SUPPORTED_LANGS)[number];

const STORAGE_KEY = "tc-lang";

/**
 * Default language is English regardless of browser locale (product
 * decision). We only honour an explicit prior choice persisted in
 * localStorage; we never auto-detect `navigator.language`.
 */
function initialLang(): Lang {
  if (typeof window === "undefined") return "en";
  const saved = window.localStorage.getItem(STORAGE_KEY);
  return saved === "zh" || saved === "en" ? saved : "en";
}

void i18n.use(initReactI18next).init({
  resources: {
    en: { landing: enLanding },
    zh: { landing: zhLanding },
  },
  lng: initialLang(),
  fallbackLng: "en",
  defaultNS: "landing",
  ns: ["landing"],
  interpolation: { escapeValue: false },
  returnNull: false,
});

// Keep <html lang> in sync and persist the user's choice.
if (typeof document !== "undefined") {
  document.documentElement.lang = i18n.language;
  i18n.on("languageChanged", (lng) => {
    document.documentElement.lang = lng;
    try {
      window.localStorage.setItem(STORAGE_KEY, lng);
    } catch {
      // localStorage unavailable (private mode) — language still switches
      // for the session, it just won't persist.
    }
  });
}

export default i18n;
