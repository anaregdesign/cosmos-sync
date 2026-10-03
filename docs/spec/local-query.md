# Local query acceptance

The first product query surface evaluates a finite immutable AST against the current authorized scope's cached document views. It does not send Cosmos SQL, partition IDs or authorization choices from clients to the server.

- AND filters support equality, inequality, numeric/string ranges and array membership. Missing fields never match. Explicit null matches only equality with null; inequality excludes null, including `ne(null)`.
- Paths are explicit field-name segments, so a literal field containing a dot is distinguishable from a nested field. Ordering excludes documents with a missing ordered field. JSON values have documented deterministic ordering, ending with ascending document ID to break ties.
- Queries support a positive result limit and exclusive snapshot-derived pagination with every ordered value plus document ID. Cursors are bound to the query definition, not server resume cursors; concurrent changes can move results across a page boundary.
- Deleted views are excluded. Pending overlays participate in filtering and ordering; old server ACKs must not replace newer local overlays. Query snapshots expose pending/conflict metadata.
- Query snapshots always report cache origin. Only a completed scope replay with a saved cursor may report coverage through that cursor. Coverage does not imply online freshness, a frozen server snapshot, current authorization while offline, or acknowledged pending writes.
- Query watches emit their first durable local view and changes including coverage-only changes. They do not open a server query listener; synchronization/change notifications refresh the cache separately.
- Tests cover null/missing fields, numeric/string type boundaries, deterministic ties, nested paths, deletion/recreation, pending/conflict overlays, pagination and immutable/validated AST decoding. Tests assert completeness changes during bootstrap, resync and revocation.

No joins, OR/IN, aggregations, collection groups, arbitrary functions, server indexes, typed Firestore timestamps/references/bytes/vectors, or full Firestore query compatibility are promised. A full replay of the authorized scope supplies the cache; query scans have explicit performance limits in the API documentation.
