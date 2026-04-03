import { Buffer } from "buffer";
import { startTransition, StrictMode } from "react";
import { hydrateRoot } from "react-dom/client";
import { HydratedRouter } from "react-router/dom";

type GlobalWithBuffer = typeof globalThis & { Buffer?: typeof Buffer };

if (!(globalThis as GlobalWithBuffer).Buffer) {
  (globalThis as GlobalWithBuffer).Buffer = Buffer;
}

startTransition(() => {
  hydrateRoot(
    document,
    <StrictMode>
      <HydratedRouter />
    </StrictMode>,
  );
});
