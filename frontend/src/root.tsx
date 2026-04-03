import "./global.css";

import type { ReactNode } from "react";
import { isRouteErrorResponse, Links, Meta, Outlet, Scripts, ScrollRestoration, useRouteError } from "react-router";

import { AppShell } from "./layout/app-shell";
import { AppProviders } from "./providers/app-providers";

function Document({ children }: { readonly children: ReactNode }) {
  const shell = <AppShell>{children}</AppShell>;

  return (
    <html lang="en">
      <head>
        <meta charSet="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <Meta />
        <Links />
      </head>
      <body suppressHydrationWarning>
        <AppProviders>{shell}</AppProviders>
        <ScrollRestoration />
        <Scripts />
      </body>
    </html>
  );
}

export function Layout({ children }: { readonly children: ReactNode }) {
  return <Document>{children}</Document>;
}

export default function Root() {
  return <Outlet />;
}

export function ErrorBoundary() {
  const error = useRouteError();

  const message = isRouteErrorResponse(error)
    ? `${error.status} ${error.statusText}`
    : error instanceof Error
      ? error.message
      : "Unexpected application error";

  return (
    <section aria-labelledby="swap-ui-error-title">
      <h1 id="swap-ui-error-title">Something went wrong</h1>
      <p>{message}</p>
    </section>
  );
}
