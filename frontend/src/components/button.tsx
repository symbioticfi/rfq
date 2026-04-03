import type { ButtonHTMLAttributes } from "react";

import styles from "./button.module.css";

type ButtonVariant = "primary" | "secondary" | "ghost";

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  readonly variant?: ButtonVariant;
  readonly fullWidth?: boolean;
};

export function Button({ variant = "primary", fullWidth = false, className, ...props }: ButtonProps) {
  const cls = [styles.button, styles[variant], fullWidth ? styles.fullWidth : "", className ?? ""]
    .filter(Boolean)
    .join(" ");

  return <button className={cls} {...props} />;
}
