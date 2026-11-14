import { en, type Dictionary } from "./en";
import { zh } from "./zh";

export type Locale = "en" | "zh";
export type { Dictionary };

const dictionaries: Record<Locale, Dictionary> = { en, zh };

export function dictionary(locale: Locale): Dictionary {
  return dictionaries[locale];
}

/** BCP 47 tag for `<html lang>`, `hreflang`, and date formatting. */
export const LANG_TAG: Record<Locale, string> = { en: "en", zh: "zh-CN" };

export function otherLocale(locale: Locale): Locale {
  return locale === "en" ? "zh" : "en";
}

/**
 * Site path of a page in a locale. English lives at the root and Chinese
 * under `/zh`. `page` is "/" or a path such as "/changelog".
 */
export function localePath(locale: Locale, page: string): string {
  if (locale === "en") return page;
  return page === "/" ? "/zh" : `/zh${page}`;
}
