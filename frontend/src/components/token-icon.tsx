import { useState } from "react";

import styles from "./token-icon.module.css";

type TokenIconProps = {
  readonly src?: string;
  readonly symbol: string;
  readonly size?: number;
};

export function TokenIcon({ src, symbol, size = 28 }: TokenIconProps) {
  const [failedSrc, setFailedSrc] = useState<string | null>(null);
  const hasError = Boolean(src && failedSrc === src);

  if (!src || hasError) {
    return (
      <div className={styles.fallback} style={{ width: size, height: size, fontSize: size * 0.4 }} aria-hidden="true">
        {symbol.slice(0, 2)}
      </div>
    );
  }

  return (
    <img
      className={styles.icon}
      src={src}
      alt=""
      aria-hidden="true"
      width={size}
      height={size}
      onError={() => setFailedSrc(src)}
    />
  );
}
