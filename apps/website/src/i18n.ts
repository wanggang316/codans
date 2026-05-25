import i18n from "i18next";
import { initReactI18next } from "react-i18next";

import enLanding from "./locales/en/landing.json";

void i18n.use(initReactI18next).init({
  resources: {
    en: { landing: enLanding },
  },
  lng: "en",
  fallbackLng: "en",
  defaultNS: "landing",
  ns: ["landing"],
  interpolation: { escapeValue: false },
  returnNull: false,
});

export default i18n;
