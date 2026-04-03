import { index, route, type RouteConfig } from "@react-router/dev/routes";

export default [
  route("/.well-known/appspecific/com.chrome.devtools.json", "routes/chrome-devtools-probe.ts"),
  route("/faucet", "routes/faucet.tsx"),
  index("routes/index.tsx"),
] satisfies RouteConfig;
