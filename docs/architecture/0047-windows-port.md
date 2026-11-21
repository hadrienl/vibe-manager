# Windows port

Status: accepted, being carried out in #481.

## Decision

Vibe Manager runs on Windows from the same Swift code base. SwiftUI does not exist there, so the
views are rewritten; everything below them is shared.

- **Toolchain:** Swift 6.4.2. Swift 6.2 cannot build swift-crypto against Visual Studio 18 on the
  runner (`STL1000`).
- **Platforms:** Windows 10 1809 at least, the first with ConPTY; x64 first.
- **Manifest:** `Package.swift` declares on Windows only the modules already ported, and no
  external dependency unless a ported module needs it. The Mac's manifest does not change.
- **Interface:** SwiftCrossUI with its WinUI backend, subject to the go/no-go of #491. If it fails,
  WinUI 3 driven directly from Swift, which keeps the shared core.
- **Rejected:** .NET, which would share nothing with the Mac and double every change to the core.

## Consequences

The Mac's behaviour does not change: Windows code sits behind `#if os(Windows)` or an existing port
of `VibeApplication`. `.github/workflows/windows.yml` reports each module, and a module becomes
required with the ticket that ports it. Later tickets of #481 record their own choices here.
