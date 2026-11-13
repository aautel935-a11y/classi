// D-08 over HTTP against the local build, with the local stack's service-role key (CI sets SUPABASE_SERVICE_ROLE_KEY).
// 1. /api/push/probe proves the server-only path and records d08_worker_seen_at WITHOUT touching any notification.
// 2. /api/push/dispatch with the key uses the worker functions (claims through worker_claim_push).
import { test, expect } from "@playwright/test";
import { localSql as sql } from "./helpers.mjs";

const SECRET = "e2e-d08-secret";
const pendingIds = async () => (await sql("select id from notifications where want_push and pushed_at is null order by id")).map((r) => r.id).join(",");
const seenAt = async () => (await sql("select value from app_secrets where key = 'd08_worker_seen_at'"))[0]?.value ?? null;

test.describe.configure({ mode: "serial" });
test.beforeEach(async ({}, info) => {
  test.skip(info.project.name !== "desktop", "database state test: once is enough");
  test.skip(!process.env.SUPABASE_SERVICE_ROLE_KEY, "needs the local service-role key");
});

test("D-08 probe: wrong or missing secret refused, nothing recorded", async ({ request }) => {
  await sql("insert into app_secrets (key, value) values ('dispatch_secret', $1) on conflict (key) do update set value = excluded.value", [SECRET]);
  await sql("delete from app_secrets where key = 'd08_worker_seen_at'");
  expect((await request.post("/api/push/probe", { data: {} })).status()).toBe(401);
  expect((await request.post("/api/push/probe", { data: { secret: "guess" } })).status()).toBe(401);
  expect(await seenAt()).toBeNull();
});

test("D-08 probe: right secret records the marker and touches no notification", async ({ request }) => {
  const user = (await sql("select id from auth.users order by created_at limit 1"))[0]?.id;
  test.skip(!user, "no account in the local stack");
  // a recent and an old (> 2 hours) waiting notification: a real claim would take the first and close the second
  await sql("insert into notifications (user_id, kind, body, want_push, created_at) values ($1, 'message', 'd08 recent', true, now()), ($1, 'message', 'd08 old', true, now() - interval '3 hours')", [user]);
  const before = await pendingIds();
  const r = await request.post("/api/push/probe", { data: { secret: SECRET } });
  expect(r.status()).toBe(200);
  expect(await r.json()).toEqual({ ok: true, probe: true, delivered: 0 });
  const seen = await seenAt();
  expect(seen).not.toBeNull();
  expect(Date.now() - new Date(seen).getTime()).toBeLessThan(60_000);
  expect(await pendingIds()).toBe(before); // not one notification changed
});

test("D-08 dispatch with the server key goes through the worker functions", async ({ request }) => {
  const r = await request.post("/api/push/dispatch", { data: { secret: SECRET } });
  expect(r.status()).toBe(200);
  const body = await r.json();
  expect(body.ok).toBe(true);
  expect(body.items).toBeGreaterThanOrEqual(1);
  // the recent one was handed over, the old one closed by the housekeeping step; nothing is left waiting
  expect((await sql("select count(*)::int n from notifications where body in ('d08 recent', 'd08 old') and pushed_at is null"))[0].n).toBe(0);
  expect((await request.post("/api/push/dispatch", { data: { secret: "guess" } })).status()).toBe(401);
});
