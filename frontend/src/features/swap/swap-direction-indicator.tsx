import { ArrowDown } from "lucide-react";

import styles from "./swap-direction-indicator.module.css";

/**
 * @dev Renders the passive center arrow between the input and output panels.
 * @returns The static direction indicator.
 */
export function SwapDirectionIndicator() {
  return (
    <div className={styles.wrapper} aria-hidden="true">
      <div className={styles.indicator}>
        <ArrowDown size={16} />
      </div>
    </div>
  );
}
