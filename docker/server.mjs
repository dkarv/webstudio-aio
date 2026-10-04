// Production server for the builder. Equivalent to remix-serve, but keeps
// Node's native fetch.
import path from "node:path";
import url from "node:url";
import express from "express";
import { createRequestHandler } from "@remix-run/express";
import { installGlobals } from "@remix-run/node";

const build = await import(
  url.pathToFileURL(path.resolve("build/server/index.js")).href
);

// The app relies on Node's native fetch (as on Vercel); the polyfill breaks PostgREST calls.
installGlobals({ nativeFetch: true });

const app = express();
app.disable("x-powered-by");
if (process.env.BEHIND_PROXY === "true") {
  // Use X-Forwarded-Proto/Host from a proxy on a private network, so request
  // URLs keep the public https origin.
  app.set("trust proxy", "loopback, linklocal, uniquelocal");
}
app.use(
  build.publicPath,
  express.static(build.assetsBuildDirectory, { immutable: true, maxAge: "1y" })
);
app.use(express.static("public", { maxAge: "1h" }));
app.all("*", createRequestHandler({ build, mode: process.env.NODE_ENV }));

const port = Number(process.env.PORT ?? 3000);
const host = process.env.HOST ?? "0.0.0.0";
const server = app.listen(port, host, () =>
  console.log(`[builder] listening on http://${host}:${port}`)
);

for (const signal of ["SIGTERM", "SIGINT"]) {
  process.once(signal, () => server.close(() => process.exit(0)));
}
