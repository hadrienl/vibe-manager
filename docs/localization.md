# Localization

Vibe Manager speaks English and French. English is the development language, and the one a string
falls back to; French is translated in full. The application follows the language macOS gives it —
System Settings › General › Language & Region, including the language chosen for this application
alone. There is no language setting in the application.

## Where the strings live

Every target whose text reaches the user has its own catalog, `Localizable.xcstrings`, next to its
sources: `VibeDomain`, `VibeApplication`, `VibePersistence`, `VibeAgents`, `VibeGit`,
`VibeTerminal`, `VibeTerminalUI` and `VibeUI` in the package, and `App/VibeManagerApp` for the
menus and alerts of the application. `App/VibeManagerApp/InfoPlist.xcstrings` holds the sentences
macOS shows on the application's behalf, when it asks for access to a folder.

The key of a string is its English text, as SwiftUI does it. A `comment:` tells the translator what
the text is about as soon as the words alone do not: what an argument stands for, which button a
sentence refers to, where a lone word is shown. A key of its own is kept for an English text that
needs two different translations, with the English as its default value: `separator.restart`
(“Restart”, the noun over a restarted terminal, where the button is a verb), `usage.column.running`
(“Running”, a column of running time, where a session's state is also “Running”),
`inspector.distance` and `notes.footer.size` (two sentences assembled from parts).

The compiler lists the strings it sees (`SWIFT_EMIT_LOC_STRINGS`), and building in Xcode adds them
to the catalogs. On the command line, `swift build` leaves `.stringsdata` files next to the objects
of each target (`.build/out/Intermediates.noindex/VibeManagerKit.build/Debug/<Target>-t.build/`),
which `xcrun xcstringstool sync <catalog> --stringsdata <file>…` merges into its catalog. After a
change to a catalog alone, the first incremental `swift build` may copy the previous strings into
the bundle: build a second time before testing a translation.

## Writing a string in the code

- **In a package, name the bundle.** A SwiftUI literal — `Text("Restart")`, `Button("Restart")`,
  `.help("…")` — is looked up in the application's catalog, where a package's strings are not, and
  is shown in English whatever the language. In the package, text is written
  `Text("Restart", bundle: .module)`, a control takes its title as a view
  (`Button { … } label: { Text("Restart", bundle: .module) }`) or as a resource
  (`Button(LocalizedStringResource("Restart", bundle: .module)) { … }`), and a sentence built in
  code is `String(localized: "…", bundle: .module)`. Each module defines
  `LocalizedStringResource.BundleDescription.module` for the resources (`Localization.swift`).
  `#bundle` would say the same, but Xcode 16.4, which CI uses, does not know it.
- **Only `Text` takes a `LocalizedStringResource` in the SDK CI builds with** (Xcode 16.4, macOS
  15). `Button`, `Label`, `Toggle`, `Picker` and `Section` titled with a resource come from
  `LocalizedStringResourceControls.swift` in `VibeUI`, which says the same through `Text`; any other
  control is given `Text(resource)` as its label. Later SDKs have these initialisers too, as
  disfavoured overloads, so the code compiles with both — but only CI tells the old one apart.
- **A text field takes its title as a view**, `TextField(text:prompt:label:)`, or as a resolved
  `String`: `TextField(_: LocalizedStringResource, text:)` only exists from macOS 26.
- **`Text(verbatim:)`** for what is shown as it is — a path, a name, `⌘1`, `→` — so that it does
  not become a key of the catalog. No key is made of placeholders alone, except `%@: %@`, whose
  French puts a no-break space before the colon.
- **A label a model hands to a view is a `LocalizedStringResource`**: the view shows it with
  `Text(_:)`, VoiceOver gets it through `String(localized:)`. A sentence assembled at run time from
  several parts, and an error message (`LocalizedError`), are a `String` resolved with
  `String(localized:bundle:)`.
- **`Text(someString)` is never translated.** A `String` reaches the screen as it is: it is either
  the user's own text, a name, or something already resolved.
- **A count is a plural**, written with its number in the sentence (`"\(count) files"`) and given
  its plural variants in the catalog — English `one` and `other`, French `one`, `many` and `other`.
  French puts 0 with 1: « 0 fichier ». The number is formatted in the user's locale, so it is grouped
  by thousands: “6,000 files”, « 6 000 fichiers ». An identifier that happens to be a number — a
  process identifier, an exit status, a revision, a byte limit quoted to the user — is interpolated
  as a `String`, so that it is not grouped.
- **A sentence is written whole**, never assembled from fragments that another language would put
  in another order or make agree differently: four sentences rather than one with a verb slotted
  in.
- Dates, durations and numbers are formatted in the user's locale (`formatted()`), which is already
  what the application does.

## What is not translated

- The diagnostics log and its export: stable tokens, never sentences (ADR 0020). The plain-text
  report of an agent's detection (`AgentDiagnostic.exportText`) and the technical `detail` of a
  diagnostic, which are for a bug report.
- The text sent to an agent — the handover brief, the context brief, the prompts: an agent answers
  in the language the user writes to it, and those texts are pinned by tests.
- Accessibility identifiers, which the interface tests look for.
- The names of the command-line tools, of the agents, of their models and options; the commands
  the user is told to type (`git config --global --add safe.directory …`).
- Git's own words: Git runs in English, because that is how its errors are recognised.
- What the user wrote: session names, notes, templates. The two example templates are written in
  the application's language on the day they are added; from then on they are the user's.

## French style

- **Vouvoiement**, and the imperative for an instruction: « Choisissez un dossier ».
- **Typography**: a no-break space (U+00A0) before `:` `;` `?` `!` and inside « » ; the typographic
  apostrophe `’`; `…` rather than three dots. Guillemets « » replace the English “ ” around a name.
- **The tone of a native Mac application**: Apple's French for the words a Mac already uses —
  Réglages…, Annuler, OK, Fermer, Enregistrer, Ne pas enregistrer, Supprimer, Afficher dans le
  Finder, Réglages Système, Accès complet au disque.
- Title case does not exist in French: only the first word of a command or a title takes a
  capital (« Nouvelle session », « Exporter les diagnostics… »).

### Glossary

| English | French |
|---|---|
| session, agent, worktree, prompt | session, agent, worktree, prompt (kept) |
| Needs attention | Action requise |
| prompt template, template | modèle de prompt, modèle |
| model (of an agent) | modèle — where both are on screen, the template is « Modèle de prompt » |
| working folder | dossier de travail |
| repository, branch, commit | dépôt, branche, commit |
| staged, unstaged, untracked, conflicted | indexé, non indexé, non suivi, en conflit |
| ahead of, behind upstream | en avance sur, en retard sur l’amont |
| merge request, pull request | merge request, pull request (kept) |
| diff | diff |
| restart (a session) | relancer |
| stop, stop all | arrêter, tout arrêter |
| close (a session, a window) | fermer |
| archive, unarchive | archiver, désarchiver |
| switch agent, switch back to… | changer d’agent, revenir à… |
| detect again | relancer la détection |
| sign in | se connecter |
| resume (a conversation) | reprendre |
| handover, hand over | passation, transmettre |
| summary | résumé |
| notes | notes |
| inspector, sidebar | inspecteur, barre latérale |
| terminal host | hôte des terminaux |
| transcript | transcript (kept) |
| conversation view, composer | vue conversation, zone de saisie |
| reasoning, sub-agent | raisonnement, sous-agent |
| attach (files) | joindre |
| usage, tokens, running time, runs | utilisation, jetons, temps d’exécution, exécutions |
| dismiss (a banner) | masquer |
| session store | fichier des sessions |
| Full Disk Access | Accès complet au disque |
| System Settings | Réglages Système |
| Reveal in Finder | Afficher dans le Finder |

## Guards

- `Scripts/check-localizations.sh`, run by `Scripts/ci.sh`, fails when a string of a catalog has no
  French translation — each plural variant included — or is marked stale or in need of review.
- The unit tests resolve the labels in both languages through `VibeLocalizationTesting`, which reads
  the `fr.lproj` of a module's bundle: `String(localized:bundle:locale:)` formats with the locale it
  is given, but still picks the table of the process's language. A test runner declares no
  localization of its own, so the strings it resolves otherwise are English, whatever the Mac's
  language.
- The interface smoke test launches the application in English (`-AppleLanguages (en)`), and one
  test launches it in French.
- French runs 20 to 30 % longer than English. The sidebar's lines are truncated already; the sheets,
  the settings and the inspector are checked with Xcode's double-length pseudolanguage.
