# 0040 — Mobile companion: a direct channel in the foreground, CloudKit for the rest

- Status: accepted
- Date: 2026-10-16
- Issues: [#347](https://github.com/hadrienl/vibe-manager/issues/347) (proof),
  [#368](https://github.com/hadrienl/vibe-manager/issues/368) (trials and this record)

## Context

An iPhone application should let the user drive Vibe Manager from away from the Mac: see the
sessions, answer an agent, follow a conversation. Two needs, of different shapes:

- **The application open**: an active, reactive channel to the Mac, both ways, for as long as the
  user looks at it.
- **The application in the background or the phone locked**: nothing but a visible notification
  when an agent waits for the user (a permission, a question). iOS suspends a background
  application's connections anyway.

One constraint rules out most of the field: **the project pays for nothing** — no relay, server,
VPS or SaaS of its own. A provider's free tier is acceptable only as an exceptional fallback, never
as the normal path. The products that do this today (Anthropic's Remote Control, OpenAI's Codex
mobile, Happy) all go through a relay their maker runs; that is the one thing this project cannot
have.

Two more constraints come from earlier records. The application holds no iCloud entitlement
(ADR 0021: no provisioning profile, a designated requirement that survives updates), so whatever
talks to iCloud on the Mac lives in a process of its own. And a Mac asleep cannot be woken by a
push: the companion says « Mac en veille », it does not try.

The POC branch `poc/347-mobile-companion` built and tried every piece below on a device (iPhone 15,
Wi-Fi and 4G, Mac on a home connection with IPv4 and IPv6). It is not merged; this record is what
#347 and #368 leave on `main`.

## Decisions

### A helper owns iCloud on the Mac

`Vibe Manager Companion.app`, in `Contents/Helpers`, with its own App ID
(`eu.hadrien.VibeManager.CompanionAgent`) and its own provisioning profile, holds iCloud and the
pushes. The application starts it, talks to it over a Unix socket whose peer each side checks
against its designated requirement (as ADR 0017 does for the terminal host), and hands it what it
publishes: presence, the sessions' summaries, the requests. The application keeps no profile and
its entitlements stay the microphone's alone. When the link closes, the helper writes the Mac
offline and quits.

A helper app with its own Developer ID profile inside another app's bundle is a supported layout
(Apple DTS). Xcode's automatic signing made the profile itself, valid for 18 years; if it ever
expired or were revoked, the helper would no longer launch, the application would.

### CloudKit: presence, discovery and requests

The private database of the user's iCloud account, in a custom zone, carries what must survive the
application being closed: whether the Mac is online, its sessions, its iroh address (below), and
the agents' requests. It costs the project nothing — each user's private database counts against
their own iCloud storage — and needs no account of ours.

- **Polling, not silent pushes.** CloudKit's silent pushes are rationed (one or two an hour at
  best, dropped past that) and unreliable on macOS since Sonoma; `CKSyncEngine` alone fetched late
  on the Mac. Each side asks the zone directly — the Mac every 5 s, the phone every 10 s while
  open; a fetch with nothing new is one request and pushes nothing to anyone. Two hours of it
  (≈ 1,500 fetches) met no rate limit.
- **Visible notifications by subscription.** The phone saves a `CKQuerySubscription` on the
  request record type with a generic alert (« Un agent attend votre réponse ») and
  `shouldSendMutableContent`. CloudKit itself sends the push; no server of ours is involved.
- **Nothing readable at Apple's push service.** A request's words — session, agent, question — are
  in `encryptedValues`. A Notification Service Extension on the phone fetches the record, decrypts
  it and writes the real title and body before iOS shows the alert; on any failure or timeout the
  generic alert goes out as it came. Without Advanced Data Protection Apple holds the keys of
  `encryptedValues`, so this is encryption at rest and in the push, end to end only with ADP.

Tried on the device: alerts on a locked phone, on Wi-Fi and 4G, with the application killed, the
text decrypted by the extension.

### The live channel: iroh, direct first

While the application is open, the phone and the Mac talk over [iroh](https://www.iroh.computer)
(QUIC, the peers named by their public keys). The helper binds an endpoint at launch and publishes
its endpoint ID and home relay in the Mac's record; the phone dials what it reads there. iroh
coordinates through a relay for the first round trip, then punches a direct path and moves to it.
The channel closes when the application goes to the background and is made anew when it returns.

Measured on the device (echo every second, 134 round trips):

| Situation | Path | Round trip (p50 / p95) |
|---|---|---|
| Setup | relay ~1 s, then direct | first echo in 0.2 s |
| Shared Wi-Fi | direct | 12 / 91 ms |
| 4G | direct (IPv6 on both ends) | 57 / 280 ms |
| Wi-Fi → 4G, application open | direct, path migrated without reconnecting | one echo at 1.5 s |
| Back from the background | new connection, direct in ~1 s | 9 / 13 ms |

Two round trips in 134 went through the relay. The macOS application firewall, enabled, did not
stop the direct path.

Layers, in order:

1. **Direct** — same network, or a hole punched through the NATs (published figures: about 70 % of
   pairs over IPv4; IPv6 on both ends, as in the trial, usually connects directly).
2. **n0's public relays** — free, without an account, rate-limited and offered for development and
   hobby use. They carry the first round trip and the pairs no hole can be punched for (carrier
   CGNAT on IPv4 alone). Acceptable as a fallback under the cost rule, not as the normal path.
3. **CloudKit** — the last resort: when neither of the above connects, the application falls back
   to the records and their polling, slower but always there.

Once the Mac's address is known, the channel no longer depends on iCloud: during the trials
`cloudd`, the macOS iCloud daemon, hung for three days (« C2 callback hung » every minute) and the
Mac looked offline to the phone while nothing else was wrong. A relaunch of `cloudd` cured it.

### The schema: a container to try in, the real one deployed once

CloudKit's Production schema only grows: types, fields and indexes can be added, never removed,
renamed or changed (a field created in clear can never become encrypted). Any build signed with
Developer ID, which is how releases ship (ADR 0021), is allowed CloudKit's **Production**
environment alone, and the pushes' production; the Development environment is out of its reach.

So the trials ran in a container of their own, `iCloud.eu.hadrien.VibeManager.Debug`, whose schema
was deployed to Production; the real container, `iCloud.eu.hadrien.VibeManager`, has nothing in
Production. Its schema is deployed once, when the implementation has settled it. A container can be
neither deleted nor renamed; the trial one stays, unused, at no cost.

## Consequences

- iroh adds about 11.5 MB stripped to each binary that links it (the iOS application, the helper),
  and the helper is arm64 only, macOS 14.5 or later. The application itself does not link it.
- IrohLib 1.1's Swift bindings panic on every `watch*` call ("there is no reactor running"); the
  POC polls `paths()` every second and `addr()` every 30 s instead. To report upstream.
- The direct channel must authenticate the phone: the POC's echo accepts any peer. The real protocol
  admits only endpoint IDs the user paired, and the helper keeps its secret key in the Keychain, not
  in a file.
- `release.sh` refuses the helper today; a release with it changes that check, notarizes the helper
  with its profile, gives the profile to the release job, and keeps the application's designated
  requirement unchanged for Sparkle and TCC.
- The phone sees the Mac only while it is awake and its helper running; a Mac asleep is said so.
- n0 may change the terms of its public relays. If they went, the direct path and CloudKit would
  remain; a relay of our own would cost money and is not an option under the cost rule.

## Alternatives set aside

- **A relay of our own, or a paid tier** (n0 Pro, a VPS, a SaaS): the way the other products work,
  ruled out by the cost rule.
- **CloudKit alone, live channel included**: no push fast enough to carry a conversation, and
  polling every second would be a request a second per user, for nothing most of the time.
- **Silent pushes for the requests**: rationed by the system, dropped when it decides, not visible.
- **The local network only** (Bonjour, `Network.framework`): free and fast, but useless away from
  home, which is the point of a companion.
- **A neutral `Envelope` record type** with one encrypted payload, so that the schema never has to
  change again: kept as an option for the implementation, which will settle the record types before
  the real container is deployed.
