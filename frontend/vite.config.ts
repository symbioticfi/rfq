import { reactRouter } from "@react-router/dev/vite";
import { defineConfig } from "vite";

type ProcessLike = {
  readonly env?: Record<string, string | undefined>;
};

const processLike = (globalThis as typeof globalThis & { readonly process?: ProcessLike }).process;
const env = processLike?.env ?? {};
const API_PROXY_TARGET = env.VITE_API_PROXY_TARGET || "http://127.0.0.1:42072";

export default defineConfig({
  plugins: [reactRouter()],
  define: {
    global: "globalThis",
  },
  resolve: {
    alias: {
      buffer: "buffer/",
    },
    dedupe: ["react", "react-dom", "react-router", "react-router/dom"],
  },
  server: {
    port: Number(env.PORT || 5173),
    proxy: {
      "/api": {
        target: API_PROXY_TARGET,
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, ""),
      },
    },
  },
  ssr: {
    noExternal: ["react-router", "react-router/dom"],
  },
});
