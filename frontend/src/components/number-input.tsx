import { type ChangeEvent, forwardRef, type InputHTMLAttributes, useCallback } from "react";

import { addCommasToInput, stripCommas } from "../utils/format-number";
import styles from "./number-input.module.css";

type NumberInputProps = {
  readonly value: string;
  readonly onChange: (value: string) => void;
} & Omit<InputHTMLAttributes<HTMLInputElement>, "onChange" | "value" | "type" | "inputMode">;

/** Allow digits, one decimal point, and prevent negative values. */
function sanitize(raw: string): string {
  let cleaned = raw.replace(/[^0-9.]/g, "");
  const dotIndex = cleaned.indexOf(".");
  if (dotIndex !== -1) {
    cleaned = cleaned.slice(0, dotIndex + 1) + cleaned.slice(dotIndex + 1).replace(/\./g, "");
  }

  return cleaned;
}

export const NumberInput = forwardRef<HTMLInputElement, NumberInputProps>(function NumberInput(
  { value, onChange, placeholder = "0", disabled = false, readOnly = false, className, ...props },
  ref,
) {
  const handleChange = useCallback(
    (e: ChangeEvent<HTMLInputElement>) => {
      // Strip commas before sanitizing so user can type freely
      const raw = sanitize(stripCommas(e.target.value));
      onChange(raw);
    },
    [onChange],
  );

  // Display with commas, store raw
  const displayValue = addCommasToInput(value);

  return (
    <input
      ref={ref}
      className={`${styles.input} ${className ?? ""}`}
      type="text"
      inputMode="decimal"
      autoComplete="off"
      autoCorrect="off"
      spellCheck={false}
      value={displayValue}
      onChange={handleChange}
      placeholder={placeholder}
      disabled={disabled}
      readOnly={readOnly}
      {...props}
    />
  );
});
