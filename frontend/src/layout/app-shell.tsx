import type { ReactNode } from "react";

import styles from "./app-shell.module.css";
import { Header } from "./header";

type AppShellProps = {
  readonly children: ReactNode;
};

export function AppShell({ children }: AppShellProps) {
  return (
    <div className={styles.shell}>
      <a className={`${styles.skipLink} srOnlyFocusable`} href="#main-content">
        Skip to Swap
      </a>
      <Header />
      <main id="main-content" className={styles.main}>
        {children}
      </main>
    </div>
  );
}
