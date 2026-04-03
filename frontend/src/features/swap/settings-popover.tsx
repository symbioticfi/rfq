import { type ChangeEvent, useCallback, useEffect, useRef, useState } from "react";

import styles from "./settings-popover.module.css";

type SettingsPopoverProps = {
  readonly id?: string;
  readonly slippageBps: number;
  readonly slippageMode: "preset" | "custom";
  readonly onSlippageChange: (bps: number, mode: "preset" | "custom") => void;
  readonly onClose: () => void;
  readonly triggerRef?: React.RefObject<HTMLButtonElement | null>;
};

/** Always format as xx.xx: 50 → "0.50", 100 → "1.00", 123 → "1.23" */
function formatSlippage(bps: number): string {
  return (bps / 100).toFixed(2);
}

const SLIPPAGE_PRESETS = [
  { bps: 10, label: "0.1%" },
  { bps: 50, label: "0.5%" },
  { bps: 100, label: "1.0%" },
] as const;

export function SettingsPopover({
  id,
  slippageBps,
  slippageMode,
  onSlippageChange,
  onClose,
  triggerRef,
}: SettingsPopoverProps) {
  const ref = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const customMode = slippageMode === "custom";
  const [rawInput, setRawInput] = useState(customMode ? formatSlippage(slippageBps) : "");

  const closeAndReturnFocus = useCallback(() => {
    onClose();
    triggerRef?.current?.focus();
  }, [onClose, triggerRef]);

  useEffect(() => {
    const handleClickOutside = (e: MouseEvent) => {
      const target = e.target as Node;
      if (
        ref.current &&
        !ref.current.contains(target) &&
        !(triggerRef?.current && triggerRef.current.contains(target))
      ) {
        closeAndReturnFocus();
      }
    };

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        closeAndReturnFocus();
      }
    };

    const timer = setTimeout(() => {
      document.addEventListener("mousedown", handleClickOutside);
      document.addEventListener("keydown", handleKeyDown);
    }, 0);

    return () => {
      clearTimeout(timer);
      document.removeEventListener("mousedown", handleClickOutside);
      document.removeEventListener("keydown", handleKeyDown);
    };
  }, [closeAndReturnFocus, triggerRef]);

  const handleSlippageInput = useCallback(
    (e: ChangeEvent<HTMLInputElement>) => {
      const raw = e.target.value;

      if (raw !== "" && !/^\d{0,2}\.?\d{0,2}$/.test(raw)) {
        return;
      }

      const val = parseFloat(raw);
      if (!Number.isNaN(val) && val > 100) {
        return;
      }

      setRawInput(raw);

      if (raw === "") {
        onSlippageChange(50, "custom");

        return;
      }

      if (!Number.isNaN(val) && val >= 0) {
        onSlippageChange(Math.round(val * 100), "custom");
      }
    },
    [onSlippageChange],
  );

  const handlePresetClick = useCallback(
    (bps: number) => {
      setRawInput("");
      onSlippageChange(bps, "preset");
    },
    [onSlippageChange],
  );

  const handleSlippageBlur = useCallback(() => {
    setRawInput(formatSlippage(slippageBps));
  }, [slippageBps]);

  const handleCustomClick = useCallback(() => {
    setRawInput(formatSlippage(slippageBps));
    onSlippageChange(slippageBps, "custom");
    setTimeout(() => inputRef.current?.focus(), 0);
  }, [onSlippageChange, slippageBps]);

  return (
    <div id={id} ref={ref} className={styles.popover} role="dialog" aria-label="Swap settings" aria-modal="false">
      <div className={styles.section}>
        <span className={styles.sectionLabel}>Slippage tolerance</span>
        <div className={styles.segmented}>
          {SLIPPAGE_PRESETS.map((preset) => (
            <button
              key={preset.bps}
              className={`${styles.segment} ${!customMode && slippageBps === preset.bps ? styles.active : ""}`}
              onClick={() => handlePresetClick(preset.bps)}
              type="button"
              aria-pressed={!customMode && slippageBps === preset.bps}
            >
              {preset.label}
            </button>
          ))}
          {customMode ? (
            <div className={`${styles.segment} ${styles.customSegment}`}>
              <input
                ref={inputRef}
                type="text"
                inputMode="decimal"
                value={rawInput}
                placeholder="0.50"
                onChange={handleSlippageInput}
                onBlur={handleSlippageBlur}
                className={styles.inlineCustomInput}
                aria-label="Custom slippage tolerance"
                autoComplete="off"
                name="slippage-tolerance"
              />
              <span className={styles.inlineSuffix}>%</span>
            </div>
          ) : (
            <button className={styles.segment} onClick={handleCustomClick} type="button">
              Custom
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
