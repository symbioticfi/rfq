import { createContext, type ReactNode, useContext, useEffect } from "react";

export type ThemePreference = "dark" | "light" | "system";
export type ResolvedTheme = Exclude<ThemePreference, "system">;

type ThemeContextValue = {
  readonly theme: ThemePreference;
  readonly resolvedTheme: ResolvedTheme;
  readonly setTheme: (theme: ThemePreference) => void;
};

const THEME_STORAGE_KEY = "symbiotic-swap-ui-theme";

const ThemeContext = createContext<ThemeContextValue>({
  theme: "dark",
  resolvedTheme: "dark",
  setTheme: () => undefined,
});

const DARK_THEME_CONTEXT: ThemeContextValue = {
  theme: "dark",
  resolvedTheme: "dark",
  setTheme: () => undefined,
};

export function ThemeProvider({ children }: { readonly children: ReactNode }) {
  useEffect(() => {
    if (typeof document === "undefined") {
      return;
    }

    document.documentElement.dataset.theme = "dark";
    document.documentElement.style.colorScheme = "dark";

    if (typeof window !== "undefined") {
      window.localStorage.setItem(THEME_STORAGE_KEY, "dark");
    }
  }, []);

  return <ThemeContext.Provider value={DARK_THEME_CONTEXT}>{children}</ThemeContext.Provider>;
}

export function useTheme() {
  return useContext(ThemeContext);
}
