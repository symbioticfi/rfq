import { createReadStream } from "node:fs";
import { access, stat } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const rootDir = resolve(fileURLToPath(new URL("./build/client", import.meta.url)));
const indexPath = resolve(rootDir, "index.html");
const host = "0.0.0.0";
const port = Number(process.env.PORT || 3000);

const contentTypes = new Map([
  [".css", "text/css; charset=utf-8"],
  [".html", "text/html; charset=utf-8"],
  [".ico", "image/x-icon"],
  [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".map", "application/json; charset=utf-8"],
  [".png", "image/png"],
  [".svg", "image/svg+xml; charset=utf-8"],
  [".txt", "text/plain; charset=utf-8"],
  [".webp", "image/webp"],
  [".woff", "font/woff"],
  [".woff2", "font/woff2"],
]);

function toSafePath(pathname) {
  const decodedPath = decodeURIComponent(pathname);
  const normalizedPath = normalize(decodedPath);
  const relativePath = normalizedPath.replace(/^(\.\.(?:[\\/]|$))+/, "");
  const candidatePath = resolve(rootDir, `.${relativePath.startsWith("/") ? relativePath : `/${relativePath}`}`);

  return candidatePath.startsWith(rootDir) ? candidatePath : indexPath;
}

async function resolveFilePath(pathname) {
  const candidatePath = pathname === "/" ? indexPath : toSafePath(pathname);

  try {
    const fileStats = await stat(candidatePath);
    if (fileStats.isFile()) {
      return candidatePath;
    }
  } catch {
    // Fall through to the SPA entrypoint.
  }

  return indexPath;
}

const server = createServer(async (request, response) => {
  if (request.method !== "GET" && request.method !== "HEAD") {
    response.writeHead(405, { "content-type": "text/plain; charset=utf-8" });
    response.end("Method Not Allowed");
    return;
  }

  const requestUrl = new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);
  const filePath = await resolveFilePath(requestUrl.pathname);

  try {
    await access(filePath);
  } catch {
    response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    response.end("Not Found");
    return;
  }

  const extension = extname(filePath).toLowerCase();
  response.writeHead(200, {
    "cache-control": extension === ".html" ? "no-cache" : "public, max-age=31536000, immutable",
    "content-type": contentTypes.get(extension) || "application/octet-stream",
  });

  if (request.method === "HEAD") {
    response.end();
    return;
  }

  createReadStream(filePath).pipe(response);
});

server.listen(port, host, () => {
  // eslint-disable-next-line no-console
  console.log(`RFQ frontend listening on ${host}:${port}`);
});
