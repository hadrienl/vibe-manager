# The landing page

The site served at <https://hadrienl.github.io/vibe-manager/>. `build.mjs` renders it into the
folder GitHub Pages serves; `Scripts/publish-appcast.sh` runs it, then generates the Sparkle feed
`appcast.xml` beside it, and the Appcast workflow deploys the whole on every change of `site/` on
`main` and on every published, edited or deleted release. Nothing generated is committed.

```
site/
  template.html   the page, with its French text; one block per page (index, changelog, contribute, docs)
  i18n/<lang>.json  the texts of each language, fr.json being the reference
  docs/<lang>/    the documentation, in English and French only: docs.json and one page per file
  assets/         style, the one script, screenshots, illustrations, icons
  assets/docs/<lang>/  the documentation's screenshots
  build.mjs       template × languages × pages → <output>/<lang>/<page>.html
```

## What the build does

- **One folder per language.** Every element carrying `data-i18n="key"` gets `key`'s text from
  `i18n/<lang>.json`, every `data-i18n-attr="alt:key"` its attribute, and every
  `%%MARKER%%` is filled in. Each page lists the others with `hreflang`, English is `x-default`,
  and the root `index.html` sends a visitor to their browser's language or to the one they chose
  in the menu last time.
- **Releases, rendered at build time.** The download buttons point at the `.dmg` of the latest
  release, pre-releases included, and the changelog shows every published release with its notes.
  A release triggers the workflow, so the page follows without a commit. The notes are written in
  French, and the other languages say so.
- **It refuses a language that lacks a text,** instead of silently showing French.

## The documentation

`/<lang>/docs/` is the user documentation, written in English and French only; the landing page
of every other language links to the English one. `docs/<lang>/docs.json` lists the pages in
their order and groups, with the words around them (the menu, "On this page", previous and next);
each page is an HTML fragment, `docs/<lang>/<slug>.html`, opening on an `<h1>` and a
`<p class="lede">`, which give the page's title and description. The build adds the menu, the list
of the page's `<h2 id>` on the right, and links to the previous and next pages. It stops when the two
languages do not have the same pages.

A screenshot is written `<vm-shot name="new-session" alt="…">caption</vm-shot>`, optionally with
`class="center"` for a narrow one: it is `assets/docs/<lang>/<name>.jpg`, shown in a light system
appearance, and `<name>-dark.jpg` in a dark one. The build reads each file's size, so the page does
not move while images load, and stops when one is missing. The screenshots are taken from a Release
build run as an isolated copy on a staged, fictitious data folder, in each language and each
appearance, at 2× (shown at 1×).

To add a page: write it in both languages, add its slug to both `docs.json`, and link it from its
neighbours.

## Preview it

```sh
node site/build.mjs /tmp/vm-site          # releases fetched from the GitHub API
cd /tmp && mkdir -p serve && ln -sfn /tmp/vm-site serve/vibe-manager
python3 -m http.server 8765 --directory serve   # http://localhost:8765/vibe-manager/
```

The pages link their assets relatively (`../assets/`), so they work under `/vibe-manager/` as on
GitHub Pages; the root redirect needs a server, the language pages open from the disk too.

## Change a text, add a language

- **A text:** change it in `template.html` and in `i18n/fr.json`, then in every other language.
  A new text needs a new key in all of them, or the build stops.
- **A language:** add `i18n/<code>.json` with the keys of `fr.json`, and a line to `LANGS` in
  `build.mjs` (its name in its own language, its Open Graph locale, `rtl` for a right-to-left
  script).

The screenshots in `assets/shots/` come from a Release build of the application run on a staged,
fictitious data folder; each exists in a light and a dark version, chosen by the visitor's system
appearance.
