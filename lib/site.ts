/** The public address of the site (share links, sitemap, calendar files, notifications). */
export const SITE = (process.env.NEXT_PUBLIC_SITE_URL || "https://classi.click").replace(/\/$/, "");

/** Staging build (NEXT_PUBLIC_DEPLOY_ENV=staging): never indexed, marked on every page, test SMS only. */
export const IS_STAGING = process.env.NEXT_PUBLIC_DEPLOY_ENV === "staging";
