import { Search } from "lucide-react";
import { type ChangeEvent, useEffect, useRef } from "react";

import styles from "./token-search-input.module.css";

type TokenSearchInputProps = {
  readonly value: string;
  readonly onChange: (value: string) => void;
};

export function TokenSearchInput({ value, onChange }: TokenSearchInputProps) {
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    // Avoid forcing the mobile keyboard open when the token dialog mounts.
    if (!window.matchMedia("(pointer: fine)").matches) {
      return;
    }

    const timer = setTimeout(() => inputRef.current?.focus(), 100);

    return () => clearTimeout(timer);
  }, []);

  return (
    <div className={styles.container}>
      <Search className={styles.icon} size={16} aria-hidden="true" />
      <input
        ref={inputRef}
        className={styles.input}
        type="text"
        placeholder="Search by name or address"
        value={value}
        onChange={(e: ChangeEvent<HTMLInputElement>) => onChange(e.target.value)}
        autoComplete="off"
        autoCapitalize="none"
        spellCheck={false}
        aria-label="Search tokens"
        name="token-search"
      />
    </div>
  );
}
