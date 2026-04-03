import { type ReactNode, useEffect, useId, useRef } from "react";
import { createPortal } from "react-dom";

import styles from "./modal.module.css";

type ModalProps = {
  readonly open: boolean;
  readonly onClose: () => void;
  readonly title?: string;
  readonly ariaLabel?: string;
  readonly headerContent?: ReactNode;
  readonly cardClassName?: string;
  readonly children: ReactNode;
};

export function Modal({ open, onClose, title, ariaLabel, headerContent, cardClassName, children }: ModalProps) {
  const titleId = useId();
  const cardRef = useRef<HTMLDivElement>(null);
  const onCloseRef = useRef(onClose);

  useEffect(() => {
    onCloseRef.current = onClose;
  }, [onClose]);

  useEffect(() => {
    if (!open) {
      return;
    }

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        onCloseRef.current();
      }
    };

    document.addEventListener("keydown", handleKeyDown);
    document.body.style.overflow = "hidden";
    cardRef.current?.focus();

    return () => {
      document.removeEventListener("keydown", handleKeyDown);
      document.body.style.overflow = "";
    };
  }, [open]);

  if (!open) {
    return null;
  }

  return createPortal(
    <div className={styles.overlay} onClick={onClose}>
      <div
        ref={cardRef}
        className={cardClassName ? `${styles.card} ${cardClassName}` : styles.card}
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-label={title ? undefined : ariaLabel}
        aria-labelledby={title ? titleId : undefined}
        tabIndex={-1}
      >
        <div className={styles.header}>
          {title ? (
            <h2 id={titleId} className={styles.title}>
              {title}
            </h2>
          ) : (
            (headerContent ?? <div />)
          )}
          <button className={styles.closeButton} onClick={onClose} type="button" aria-label="Close">
            &times;
          </button>
        </div>
        {children}
      </div>
    </div>,
    document.body,
  );
}
