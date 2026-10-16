# 0041 — Mobile companion: one encrypted record type in CloudKit

- Status: accepted
- Date: 2026-10-16
- Issues: [#396](https://github.com/hadrienl/vibe-manager/issues/396); follows ADR 0042

## Context

ADR 0042 puts the companion's lasting state in the private database of the user's iCloud account:
the Mac's presence and iroh address, its sessions, the agents' requests. The trials wrote one record
type per need (`Mac`, `Session`, `Ping`, `Pong`, `Request`) in a container of their own,
`iCloud.eu.hadrien.VibeManager.Debug`. The real container, `iCloud.eu.hadrien.VibeManager`, has
nothing in Production yet, and its schema has to be fixed before anything ships.

A Production schema only grows. A record type, a field or an index can be added; nothing can be
removed, renamed or have its kind changed, and a field first written in the clear can never become
encrypted. Every deploy is done by hand in the CloudKit console and is final. The tickets that
follow will need records the trials never had: the paired phones (#398), the channel's fallback
through the records (#399), the answers sent from a notification (#401).

## Decision

**One record type, `Envelope`, for every record of the companion.**

| Field | Kind | Index | Holds |
|---|---|---|---|
| `kind` | `STRING`, in the clear | queryable | What the record is: `mac`, `session`, `request`… |
| `payload` | `BYTES`, `encryptedValues` | none (an encrypted field cannot have one) | The record's value as JSON, `{"v": <format>, "body": {…}}` |

- **The kind is the only thing in the clear.** It is what the request subscription filters on
  (`kind == "request"`), and says nothing of a session. Names, titles, agents, messages, the
  states, the Mac's iroh address and even the dates are in the payload, out of reach of CloudKit's
  servers and of Apple's push service (end to end with Advanced Data Protection, at rest and in the
  push otherwise, ADR 0042).
- **A new kind or field is the application's business.** A version of the application reads the
  kinds it knows and skips the others; a reader skips a payload whose format `v` is later than its
  own. Neither ever needs a schema deploy.
- **The record's name is its identity**, as in the trials: `mac-<installation>`,
  `session-<uuid>`, `request-<uuid>`. A record whose payload names another record is not read.
- **No debug type in the schema.** The trials' test (`Ping`, `Pong`) is only a kind of the debug
  application, which no shipping build writes.

The schema lives in `Configuration/CloudKit/companion.ckdb`. `Scripts/companion-schema.sh` applies it
to the real container's Development environment with `cktool`; Production is deployed once from the
console, after the Development environment has been reset (the trials once wrote their types there)
and holds exactly this file.

## Consequences

- The CloudKit console no longer shows anything readable of a record: its kind and an encrypted
  blob. Debugging goes through the application's journal, which decodes them.
- Queries on a record's content are impossible. The companion never makes any: it fetches its zone's
  changes and filters locally; only the subscription queries, on `kind`.
- A payload is JSON of the shared Swift values: a property is never renamed without raising the
  format, or old readers drop the record.
- One record weighs a few hundred bytes more than with typed fields (the JSON keys), far below
  CloudKit's limits and the user's iCloud storage.

## Alternatives set aside

- **One record type per need**, as in the trials: readable in the console, but every new need is a
  deploy, and a field mistakenly written in the clear stays in the schema for good.
- **Every field encrypted under typed record types**: as private as the envelope, with the same
  deploy per change.
- **The same envelope without a clear kind**: the subscription would fire on every record — the
  Mac's presence every few seconds — and wake the phone's extension for nothing.
