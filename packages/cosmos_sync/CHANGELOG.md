# 0.2.0-dev.1

- Await durable writes through an async-capable CacheStore, with native SQLite
  and Chromium IndexedDB persistence and exclusive lifetime ownership.
- Add deterministic scoped local queries, query watches and coverage metadata.
- Bind sessions to principal, user/shared-tenant mode and current permission.
- Add bounded snapshot bootstrap, generation recovery, authenticated change hints
  with polling recovery, and captured pending-write acknowledgment waits.
- Keep exact outbox identities, observed bases and ambiguous retry outcomes across
  restart/reset; preserve explicit conflict and conservative revocation behavior.
- Breaking changes to the unpublished 0.1 API: await put/delete/retry/discard.
- Public license and publication remain undecided; this is not a released package.

# 0.1.0-dev.1

- Initial native offline documents, SQLite cache/outbox, OIDC HTTP transport,
  scoped journal replay, explicit conflicts and polling.
