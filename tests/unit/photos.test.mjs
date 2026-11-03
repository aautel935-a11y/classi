// Photos: unique file per upload, which links an owner may save, and which files cleanup may delete (lib/photos.ts).
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { newPhotoName, isKindFile, photoPath, validPhotoUrl, photosToDelete, noLongerUsed, PHOTO_MIN_AGE_MS } = require(`${process.env.CLASSI_LIB}/photos.js`);

const HOST = "nfipmylyahhogykikuqo.supabase.co";
const A = "11111111-1111-4111-8111-111111111111";      // the signed-in owner
const B = "22222222-2222-4222-8222-222222222222";      // someone else
const url = (path, host = HOST, proto = "https") => `${proto}://${host}/storage/v1/object/public/avatars/${path}`;

test("every upload gets a new, unique file name of its kind", () => {
  const names = new Set(Array.from({ length: 2000 }, () => newPhotoName("teacher")));
  assert.equal(names.size, 2000);
  for (const n of names) assert.ok(isKindFile(n, "teacher"), n);
  assert.match(newPhotoName("profile", 1793700000000, 0.5), /^profile-[0-9a-z]+-[0-9a-z]{8}\.jpg$/);
  assert.notEqual(newPhotoName("institute", 1, 0.1), newPhotoName("institute", 1, 0.2));
});

test("file kinds: the old fixed name still counts, other kinds and other names never do", () => {
  assert.ok(isKindFile("teacher.jpg", "teacher"));                       // photos saved before unique names
  assert.ok(isKindFile("teacher-mh0abc12-a1b2c3d4.jpg", "teacher"));
  assert.ok(!isKindFile("teacher-mh0abc12-a1b2c3d4.jpg", "profile"));
  assert.ok(!isKindFile("profile.jpg", "teacher"));
  for (const bad of ["teacher-.jpg", "teacher-x-y.jpg", "teacher-mh0abc12-a1b2c3d4.png", "../teacher.jpg", "teacher.jpg/x", "TEACHER.jpg"]) {
    assert.ok(!isKindFile(bad, "teacher"), bad);
  }
});

test("photoPath reads <owner>/<file> from a public link and nothing else", () => {
  assert.equal(photoPath(url(`${A}/teacher.jpg`) + "?v=123"), `${A}/teacher.jpg`);
  assert.equal(photoPath(null), null);
  assert.equal(photoPath("not a url"), null);
  assert.equal(photoPath(`https://${HOST}/storage/v1/object/public/other-bucket/${A}/x.jpg`), null);
  assert.equal(photoPath(url(`${A}/sub/teacher.jpg`)), null);              // deeper paths
  assert.equal(photoPath(url(`${A}/%2E%2E`)), null);                       // encoded ".."
  assert.equal(photoPath(url(`/teacher.jpg`)), null);                      // empty folder
});

test("an owner may save only their own folder, their kind, https, this project", () => {
  const ok = (u, kind = "teacher") => validPhotoUrl(u, { host: HOST, owner: A, kind });
  assert.ok(ok(url(`${A}/${newPhotoName("teacher")}`)));
  assert.ok(ok(url(`${A}/teacher.jpg`) + "?v=1"));
  assert.ok(!ok(url(`${B}/${newPhotoName("teacher")}`)), "someone else's folder");
  assert.ok(!ok(url(`${A}/${newPhotoName("profile")}`)), "another kind's file");
  assert.ok(!ok(url(`${A}/${newPhotoName("teacher")}`, "rfxhqcagdsuhkjzwbawx.supabase.co")), "another project");
  assert.ok(!ok(url(`${A}/${newPhotoName("teacher")}`, HOST, "http")), "not https");
  assert.ok(!ok(url(`${A}/${newPhotoName("teacher")}`, `${HOST}.evil.com`)), "look-alike host");
  assert.ok(!ok(`https://x:y@${HOST}/storage/v1/object/public/avatars/${A}/teacher.jpg`), "credentials in the link");
  assert.ok(!ok(url(`${A}/../${B}/teacher.jpg`)), "path tricks");
  assert.ok(!ok("javascript:alert(1)"));
});

const now = Date.parse("2026-11-03T12:00:00Z");
const ago = (ms) => new Date(now - ms).toISOString();
const old = ago(PHOTO_MIN_AGE_MS + 1000), fresh = ago(30_000);

test("cleanup never deletes the approved photo or the one waiting for review", () => {
  const files = [
    { name: "teacher.jpg", created_at: old },                         // approved (old fixed name)
    { name: "teacher-a1-aaaaaaaa.jpg", created_at: old },              // waiting for review
    { name: "teacher-a2-bbbbbbbb.jpg", created_at: old },              // rejected earlier: unused
    { name: "profile-a3-cccccccc.jpg", created_at: old },              // another kind: never touched here
  ];
  const del = photosToDelete({ owner: A, kind: "teacher", files, now, keep: [`${A}/teacher.jpg`, `${A}/teacher-a1-aaaaaaaa.jpg`] });
  assert.deepEqual(del, [`${A}/teacher-a2-bbbbbbbb.jpg`]);
});

test("cleanup keeps a fresh upload (its link may still be being saved) and files of unknown age", () => {
  const files = [{ name: "teacher-a4-dddddddd.jpg", created_at: fresh }, { name: "teacher-a5-eeeeeeee.jpg", created_at: null }, { name: "teacher-a6-ffffffff.jpg" }];
  assert.deepEqual(photosToDelete({ owner: A, kind: "teacher", files, now, keep: [] }), []);
});

test("cleanup returns paths inside the owner's folder only, whatever the listing contains", () => {
  const files = [{ name: "teacher-a7-gggggggg.jpg", created_at: old }, { name: `../${B}/teacher.jpg`, created_at: old }];
  for (const p of photosToDelete({ owner: A, kind: "teacher", files, now, keep: [] })) assert.ok(p.startsWith(`${A}/`) && p.split("/").length === 2, p);
});

test("a replaced or removed photo is deleted at once, only if it is the owner's file of that kind", () => {
  // profile photo replaced: the old one goes
  assert.deepEqual(noLongerUsed({ owner: A, kind: "profile", before: [`${A}/profile.jpg`], after: [`${A}/profile-b1-aaaaaaaa.jpg`] }), [`${A}/profile.jpg`]);
  // teacher photo replaced while the first new one was still waiting: approved stays, the superseded one goes
  assert.deepEqual(noLongerUsed({ owner: A, kind: "teacher", before: [`${A}/teacher.jpg`, `${A}/teacher-b2-bbbbbbbb.jpg`], after: [`${A}/teacher.jpg`, `${A}/teacher-b3-cccccccc.jpg`] }), [`${A}/teacher-b2-bbbbbbbb.jpg`]);
  // removal waiting for review: the approved photo stays
  assert.deepEqual(noLongerUsed({ owner: A, kind: "teacher", before: [`${A}/teacher.jpg`, null], after: [`${A}/teacher.jpg`, null] }), []);
  // never someone else's file, never another kind
  assert.deepEqual(noLongerUsed({ owner: A, kind: "teacher", before: [`${B}/teacher.jpg`, `${A}/profile.jpg`], after: [] }), []);
});
