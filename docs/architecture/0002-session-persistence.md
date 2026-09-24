# ADR 0002: Session persistence

- Status: Accepted
- Date: 2026-09-21
- Decision owners: Vibe Manager maintainers
- Related issue: [#2](https://github.com/hadrienl/vibe-manager/issues/2)

## Context

Vibe Manager must retain enough metadata to identify, present and resume work sessions after an
application restart. This metadata includes the rendered initial prompt, agent identifiers,
appearance, lifecycle dates, repositories, a bounded Git snapshot, notes and the template
reference. Terminal transcripts, process environments and credentials are deliberately outside
the model.

The V1 expects a small number of sessions and does not need relational queries. Persistence must
still be atomic, migratable and recoverable because this file is the durable source of truth for
the user's workspace.

## Decision

`VibeDomain` owns a storage-independent `WorkSession` value and its lifecycle state machine.
`VibeApplication` exposes `SessionRepository` and `SessionStoreRecovery` ports. The concrete
`FileSessionRepository` is an actor in `VibePersistence`, while the in-memory implementation
remains available to tests and previews.

The durable store is a JSON envelope at
`Application Support/com.hadrienl.VibeManager/sessions.json`. It has an explicit integer schema
version and uses persistence-only DTOs rather than encoding domain values directly. V1 includes a
V0-to-V1 migration for the minimal model created with the project foundation. Unknown future
versions are rejected without modifying the file.

Every mutation of an existing session goes through `SessionRepository.mutate(id:_:)`. Pairing a
read with a write would cross two suspension points, so two concurrent transitions would read the
same snapshot and the later write would discard the earlier one.

Dates are persisted as ISO-8601 strings with millisecond precision. Domain values are normalized
to that precision when they enter the model, so a reloaded session compares equal to the one it
was built from instead of differing by a fraction of a millisecond. Lifecycle timestamps are also
clamped to the session's last update: a system clock stepping backwards must not prevent the user
from closing or archiving a session.

Writes are serialized by the repository actor. Data is written and synchronized to a unique
temporary file in the destination directory, then atomically moved or replaced. Before replacing
an existing primary file, its bytes are atomically copied to `sessions.backup.json`. Files use
mode `0600`, and a store directory created by the application uses `0700`. A directory that
already exists keeps its own permissions: the store location is caller-provided and may sit inside
a directory the application does not own.

Reading a legacy document migrates it in memory and writes it back on a best-effort basis, so a
read never fails because of the rewrite. A mutation loads without rewriting and commits once,
which leaves the pre-migration document as the backup rather than an already migrated copy of it.

A malformed or invalid primary document produces a typed error. If the backup decodes and
validates, recovery is reported as available but is never automatic. Explicit restoration re-checks
that recovery is still needed, preserves the damaged bytes in a uniquely named quarantine file, and
only then writes a current-schema document from the backup. Failing to preserve those bytes aborts
the restoration.

Two states are reported as explicitly non-restorable rather than as damage: a document written by
an unknown future version, which an older backup would silently downgrade, and a store whose bytes
cannot be read at all, which cannot be quarantined and whose replacement would destroy the only
diagnostic evidence left.

The persisted schema is an allowlist. It contains no terminal output, command history, process
environment, access token, credential-bearing remote URL or runtime adapter. Prompts, notes and
local paths are user data and must remain private in logs.

Since #16 the notes are no longer kept in this document: they are saved while the user types, and
live in a file per session next to it (ADR 0016). The v4 `notes` field is only read, once, to import
what an older store held; nothing writes it any more.

## Consequences

- Session metadata survives application restarts without adding a third-party dependency.
- Domain and application modules remain independent of Foundation file APIs and storage DTOs.
- Store migrations and failure modes can be tested with small fixtures and temporary directories.
- The whole document is rewritten for each mutation. This is acceptable for V1 volume but is not
  suitable for unbounded transcripts, which are intentionally excluded.
- The actor protects concurrent access within one process. Multi-process coordination and cloud
  synchronization would require a different implementation behind the same ports.
- The backup contains the same private metadata as the primary and receives identical file
  permissions.

## Rejected alternatives

- SwiftData was rejected because its context lifecycle and opaque migration machinery add
  complexity without helping the small, whole-document workload.
- SQLite was rejected because V1 does not need relational queries or incremental updates. It
  remains a viable future implementation behind `SessionRepository`.
- Directly encoding `WorkSession` was rejected because it would make every domain refactor an
  accidental disk-schema change.
- Silent fallback to the backup was rejected because it could hide data loss and overwrite useful
  diagnostic evidence.
