import i18n from "i18next";
import LanguageDetector from "i18next-browser-languagedetector";
import { initReactI18next } from "react-i18next";
import { coreMessages } from "./i18n-resources";

const resources = {
  "zh-CN": {
    translation: {
      language: "界面语言",
      languages: { "zh-CN": "简体中文", en: "English" },
      core: coreMessages["zh-CN"],
    },
  },
  en: {
    translation: {
      language: "Interface language",
      languages: { "zh-CN": "简体中文", en: "English" },
      core: coreMessages.en,
    },
  },
} as const;

function initialLanguage(): "en" | "zh-CN" {
  try {
    const saved = localStorage.getItem("longx:language");
    if (saved === "en" || saved === "zh-CN") return saved;
  } catch {
    // Storage can be unavailable in private browsing.
  }
  return typeof navigator !== "undefined" && navigator.language.toLowerCase().startsWith("en") ? "en" : "zh-CN";
}

void i18n
  .use(LanguageDetector)
  .use(initReactI18next)
  .init({
    resources,
    lng: initialLanguage(),
    fallbackLng: "zh-CN",
    supportedLngs: ["zh-CN", "en"],
    detection: {
      order: ["localStorage", "navigator"],
      lookupLocalStorage: "longx:language",
      caches: ["localStorage"],
    },
    interpolation: { escapeValue: false },
    returnNull: false,
  });

export default i18n;
