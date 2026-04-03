import styles from "./spinner.module.css";

type SpinnerProps = {
  readonly size?: number;
};

export function Spinner({ size = 16 }: SpinnerProps) {
  return (
    <svg
      className={styles.spinner}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
    >
      <circle
        cx="12"
        cy="12"
        r="10"
        stroke="currentColor"
        strokeWidth="2.5"
        strokeLinecap="round"
        strokeDasharray="50 20"
      />
    </svg>
  );
}
