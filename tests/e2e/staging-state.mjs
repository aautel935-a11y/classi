import { resolve } from "node:path";
/** Where the staging bypass cookie is kept (outside "results", which Playwright may clear and CI may upload). */
export const BYPASS_STATE = resolve(process.env.RUNNER_TEMP || "/tmp", "classi-staging-bypass.json");
