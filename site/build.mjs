#!/usr/bin/env node
// Renders the landing page into the folder GitHub Pages serves: one folder per language, each with
// index.html, changelog.html and contribute.html, the shared assets, and a root index.html that
// sends a visitor to their language. No dependency: Node 20 or later is enough.
//
//   node site/build.mjs <output folder> [releases.json]
//
// releases.json is the GitHub API's list of releases, as `gh api --paginate --slurp` writes it
// (Scripts/publish-appcast.sh passes the one it reads for the feed). Without it, the list is
// fetched from the API; if that fails too, the changelog links to GitHub Releases instead.

import { cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = "hadrienl/vibe-manager";
const GH = `https://github.com/${REPO}`;
const SITE_URL = "https://hadrienl.github.io/vibe-manager/";
const SOURCE_LANG = "fr";
const DEFAULT_LANG = "en";

// Order of the language menu. The third field marks a right-to-left script.
const LANGS = [
  ["en", "English", "en_US"], ["fr", "Français", "fr_FR"], ["de", "Deutsch", "de_DE"],
  ["es", "Español", "es_ES"], ["it", "Italiano", "it_IT"], ["pt-BR", "Português (Brasil)", "pt_BR"],
  ["nl", "Nederlands", "nl_NL"], ["pl", "Polski", "pl_PL"], ["tr", "Türkçe", "tr_TR"],
  ["uk", "Українська", "uk_UA"], ["ru", "Русский", "ru_RU"], ["ar", "العربية", "ar_AR", "rtl"],
  ["hi", "हिन्दी", "hi_IN"], ["ja", "日本語", "ja_JP"], ["ko", "한국어", "ko_KR"],
  ["zh-CN", "简体中文", "zh_CN"], ["zh-TW", "繁體中文", "zh_TW"],
];

// The documentation exists in fewer languages than the landing page: each one has its folder in
// docs/, and the others link to the English one.
const DOC_LANGS = ["en", "fr"];

const PAGES = [
  { id: "index", file: "index.html", href: "", title: (t) => `Vibe Manager · ${strip(t("hero.title"))}`, description: "hero.lede" },
  { id: "changelog", file: "changelog.html", href: "changelog.html", title: (t) => `${strip(t("nav.changelog"))} · Vibe Manager`, description: "cl.lede" },
  { id: "contribute", file: "contribute.html", href: "contribute.html", title: (t) => `${strip(t("nav.contribute"))} · Vibe Manager`, description: "contrib.lede" },
];

// The avatar's expressions, in the order of AvatarExpression.allCases: the page shows them in a row.
const AVATAR_EXPRESSIONS = ["neutral", "mouthHalfOpen", "mouthOpen", "mouthRound", "eyesHalfClosed",
  "eyesClosed", "pleased", "surprised", "thinking", "worried"];

const here = dirname(fileURLToPath(import.meta.url));
const [outArg, releasesArg] = process.argv.slice(2);
if (!outArg) {
  console.error("usage: node site/build.mjs <output folder> [releases.json]");
  process.exit(1);
}
const out = resolve(outArg);

const template = readFileSync(join(here, "template.html"), "utf8");
const dicts = Object.fromEntries(LANGS.map(([code]) => [code, JSON.parse(readFileSync(join(here, "i18n", `${code}.json`), "utf8"))]));
const reference = dicts[SOURCE_LANG];

// Every language must carry exactly the keys of the reference: a missing text would silently show French.
let broken = false;
for (const [code, dict] of Object.entries(dicts)) {
  const missing = Object.keys(reference).filter((k) => !(k in dict));
  const extra = Object.keys(dict).filter((k) => !(k in reference));
  if (missing.length || extra.length) {
    console.error(`i18n/${code}.json: missing ${missing.join(", ") || "none"}; unknown ${extra.join(", ") || "none"}`);
    broken = true;
  }
}
if (broken) process.exit(1);

const docs = loadDocs();

const releases = (await loadReleases()).filter((r) => !r.draft);
const latest = releases[0];

mkdirSync(out, { recursive: true });
cpSync(join(here, "assets"), join(out, "assets"), { recursive: true });

for (const [code, , ogLocale, dir] of LANGS) {
  const t = translator(code);
  mkdirSync(join(out, code), { recursive: true });
  for (const page of PAGES) {
    writeFileSync(join(out, code, page.file), renderPage(code, dir === "rtl" ? "rtl" : "ltr", ogLocale, page, t));
  }
  if (!docs[code]) continue;
  mkdirSync(join(out, code, "docs"), { recursive: true });
  for (const doc of docs[code].pages) {
    const page = {
      id: "docs", file: `docs/${doc.file}`, href: doc.slug === "index" ? "docs/" : `docs/${doc.file}`, doc, depth: 1, langs: DOC_LANGS,
      title: () => doc.slug === "index" ? docs[code].meta.title : `${strip(doc.title)} · ${docs[code].meta.title}`,
    };
    writeFileSync(join(out, code, "docs", doc.file), renderPage(code, "ltr", ogLocale, page, t));
  }
}
writeFileSync(join(out, "index.html"), renderRoot());
const docPages = DOC_LANGS.reduce((n, c) => n + docs[c].pages.length, 0);
console.log(`site: ${LANGS.length} languages × ${PAGES.length} pages, ${docPages} documentation pages, ${releases.length} releases → ${out}`);

// ---------------------------------------------------------------------------------------------

async function loadReleases() {
  if (releasesArg) {
    // `--slurp` wraps each page of the paginated list in an array of its own.
    return JSON.parse(readFileSync(releasesArg, "utf8")).flat();
  }
  try {
    const response = await fetch(`https://api.github.com/repos/${REPO}/releases?per_page=100`, {
      headers: { accept: "application/vnd.github+json", "user-agent": "vibe-manager-site" },
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return await response.json();
  } catch (error) {
    console.warn(`site: no releases (${error.message}); the changelog will link to GitHub Releases`);
    return [];
  }
}

function translator(code) {
  const dict = dicts[code];
  return (key, vars = {}) => {
    let s = dict[key] ?? reference[key];
    if (s == null) throw new Error(`unknown text ${key}`);
    for (const [k, v] of Object.entries(vars)) s = s.split(`{${k}}`).join(v);
    return s;
  };
}

function renderPage(code, dir, ogLocale, page, t) {
  const block = new RegExp(`<!--PAGE:(\\w+)-->([\\s\\S]*?)<!--/PAGE:\\1-->`, "g");
  let html = template.replace(block, (_, id, content) => (id === page.id ? content.trim() : ""));

  const version = latest ? latest.tag_name.replace(/^v/, "") : null;
  const up = "../".repeat(page.depth || 0);
  const langs = LANGS.filter(([c]) => !page.langs || page.langs.includes(c));
  const docsLang = docs[code] ? code : DEFAULT_LANG;
  const markers = {
    LANG: code,
    DIR: dir,
    TITLE: escapeAttr(page.title(t)),
    DESCRIPTION: page.description ? escapeAttr(strip(t(page.description))) : "",
    CANONICAL: `${SITE_URL}${code}/${page.href}`,
    ALTERNATES: [
      ...langs.map(([c]) => `<link rel="alternate" hreflang="${c}" href="${SITE_URL}${c}/${page.href}">`),
      `<link rel="alternate" hreflang="x-default" href="${SITE_URL}${DEFAULT_LANG}/${page.href}">`,
    ].join("\n"),
    OG_LOCALE: ogLocale,
    SITE_URL,
    LANG_OPTIONS: langs.map(([c, name]) =>
      `<option value="${c}" data-href="${up}../${c}/${page.href}"${c === code ? " selected" : ""}>${name}</option>`).join(""),
    ASSETS: `${up}../assets/`,
    HOME: up,
    DOCS_HREF: page.id === "docs" ? "./" : docsLang === code ? "docs/" : `../${docsLang}/docs/`,
    ...(page.doc ? docMarkers(code, page.doc) : {}),
    DOWNLOAD_URL: latest ? downloadURL(latest) || latest.html_url : `${GH}/releases`,
    VERSION: version ? withVersion(t, "js.version", version) : "",
    VERSION_LONG: version ? withVersion(t, "js.version_long", version) : escapeHTML(strip(t("hero.meta_macos"))),
    RELEASE_NAV: releases.map((r) => releaseNavItem(r, code)).join(""),
    RELEASE_LIST: releaseList(code, t),
    AVATAR_SPRITES: AVATAR_EXPRESSIONS
      .filter((name) => existsSync(join(here, "assets", "img", "sprites", `${name}.png`)))
      .map((name) => `<li><img src="../assets/img/sprites/${name}.png" alt="" width="44" height="44" loading="lazy"></li>`).join(""),
    ISSUE_BUG: escapeAttr(issueURL("bug", t)),
    ISSUE_IDEA: escapeAttr(issueURL("idea", t)),
  };
  html = html.replace(/%%([A-Z_]+)%%/g, (whole, name) => {
    if (!(name in markers)) throw new Error(`unknown marker ${whole}`);
    return markers[name];
  });

  // Texts, then attributes, from the language's dictionary.
  html = html.replace(/<(\w+)\b([^>]*?)\bdata-i18n="([^"]+)"([^>]*)>([\s\S]*?)<\/\1>/g,
    (_, tag, before, key, after) => `<${tag}${before}data-i18n="${key}"${after}>${t(key)}</${tag}>`);
  html = html.replace(/<[^>]*\bdata-i18n-attr="([^"]+)"[^>]*>/g, (tagText, spec) => {
    for (const pair of spec.split(";")) {
      const [attr, key] = pair.split(":");
      tagText = tagText.replace(new RegExp(`(\\s${attr}=)"[^"]*"`), (_, name) => `${name}"${escapeAttr(t(key))}"`);
    }
    return tagText;
  });

  // The current page in the menu, and the notice that release notes are written in French.
  html = html.replace(new RegExp(`data-nav="${page.id}"`, "g"), `data-nav="${page.id}" aria-current="page"`);
  if (code !== SOURCE_LANG) html = html.replace(' id="cl-lang" hidden', ' id="cl-lang"');
  return html;
}

// --- Documentation ----------------------------------------------------------------------------
//
// docs/<lang>/docs.json names the pages in their order, grouped, and the words around them;
// docs/<lang>/<slug>.html is the body of each page. A body may use <vm-shot name="…" alt="…">caption</vm-shot>,
// rendered as a screenshot from assets/docs/<lang>/<name>.jpg, with <name>-dark.jpg for a dark system appearance.

function loadDocs() {
  const all = {};
  let failed = false;
  for (const code of DOC_LANGS) {
    const folder = join(here, "docs", code);
    const meta = JSON.parse(readFileSync(join(folder, "docs.json"), "utf8"));
    const pages = meta.groups.flatMap((group) => group.pages.map((slug) => {
      const source = readFileSync(join(folder, `${slug}.html`), "utf8");
      const title = source.match(/<h1([^>]*)>([\s\S]*?)<\/h1>/);
      const lede = source.match(/<p class="lede">([\s\S]*?)<\/p>/);
      if (!title || !lede) { console.error(`docs/${code}/${slug}.html: an <h1> and a <p class="lede"> are required`); failed = true; }
      const short = title?.[1].match(/data-short="([^"]*)"/)?.[1];
      return { slug, file: slug === "index" ? "index.html" : `${slug}.html`, group: group.title, source, title: title?.[2] ?? slug, short: short ?? title?.[2] ?? slug, lede: lede?.[1] ?? "" };
    }));
    all[code] = { meta, pages };
  }
  const reference = all[DOC_LANGS[0]].pages.map((p) => p.slug).join(" ");
  for (const code of DOC_LANGS) {
    if (all[code].pages.map((p) => p.slug).join(" ") !== reference) {
      console.error(`docs/${code}/docs.json: the pages differ from docs/${DOC_LANGS[0]}/docs.json`);
      failed = true;
    }
  }
  if (failed) process.exit(1);
  return all;
}

function docMarkers(code, doc) {
  const { meta, pages } = docs[code];
  const index = pages.indexOf(doc);
  const href = (p) => p.slug === "index" ? "./" : p.file;
  const body = renderDocBody(code, doc);
  const toc = [...body.matchAll(/<h2 id="([^"]+)"[^>]*>([\s\S]*?)<\/h2>/g)];

  const groups = meta.groups.map((group) => `<div class="docs-group"><p>${escapeHTML(group.title)}</p>${pages
    .filter((p) => p.group === group.title)
    .map((p) => `<a href="${href(p)}"${p === doc ? ' aria-current="page"' : ""}>${p.short}</a>`).join("")}</div>`).join("");
  const neighbour = (p, rel, label) => p
    ? `<a class="pager-${rel}" rel="${rel}" href="${href(p)}"><small>${escapeHTML(label)}</small><span>${p.short}</span></a>`
    : "<span></span>";
  const source = `https://github.com/${REPO}/blob/main/site/docs/${code}/${doc.slug}.html`;

  return {
    DESCRIPTION: escapeAttr(strip(doc.lede)),
    DOCS_NAV_LABEL: escapeAttr(meta.navLabel),
    DOCS_NAV: groups,
    DOCS_BODY: body,
    DOCS_TOC: toc.length > 1
      ? `<p>${escapeHTML(meta.onThisPage)}</p>${toc.map(([, id, text]) => `<a href="#${id}">${strip(text)}</a>`).join("")}<a class="docs-edit" href="${source}">${escapeHTML(meta.edit)}</a>`
      : `<a class="docs-edit" href="${source}">${escapeHTML(meta.edit)}</a>`,
    DOCS_PAGER: `<nav class="docs-pager" aria-label="${escapeAttr(meta.pagerLabel)}">${neighbour(pages[index - 1], "prev", meta.previous)}${neighbour(pages[index + 1], "next", meta.next)}</nav>`,
  };
}

function renderDocBody(code, doc) {
  let first = true;
  return doc.source.replace(/<h1 [^>]*>/, "<h1>").replace(/<vm-shot\b([^>]*)>([\s\S]*?)<\/vm-shot>/g, (_, attrs, caption) => {
    const attr = (name) => attrs.match(new RegExp(`\\b${name}="([^"]*)"`))?.[1];
    const name = attr("name");
    const light = `assets/docs/${code}/${name}.jpg`;
    const dark = `assets/docs/${code}/${name}-dark.jpg`;
    if (!existsSync(join(here, light))) throw new Error(`docs/${code}/${doc.slug}.html: no screenshot ${light}`);
    const [width, height] = jpegSize(join(here, light));
    const size = ` width="${Math.round(width / 2)}" height="${Math.round(height / 2)}"`;
    const darkSource = existsSync(join(here, dark))
      ? `<source srcset="../../${dark}" media="(prefers-color-scheme: dark)">` : "";
    const classes = ["doc-shot", attr("class")].filter(Boolean).join(" ");
    const loading = first ? "" : ' loading="lazy"';
    first = false;
    return `<figure class="${classes}"><a href="../../${light}"><picture>${darkSource}<img src="../../${light}" alt="${attr("alt") ?? ""}"${size}${loading} decoding="async"></picture></a>${caption.trim() ? `<figcaption>${caption.trim()}</figcaption>` : ""}</figure>`;
  });
}

// The pixel size of a JPEG, read from its first start-of-frame segment.
function jpegSize(path) {
  const b = readFileSync(path);
  for (let i = 2; i < b.length;) {
    const marker = b[i + 1];
    const length = b.readUInt16BE(i + 2);
    if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) {
      return [b.readUInt16BE(i + 7), b.readUInt16BE(i + 5)];
    }
    i += 2 + length;
  }
  throw new Error(`${path}: not a JPEG`);
}

function renderRoot() {
  const codes = LANGS.map(([c]) => c);
  const links = LANGS.map(([c, name]) => `<li><a href="${c}/" hreflang="${c}" lang="${c}">${name}</a></li>`).join("\n      ");
  return `<!doctype html>
<!-- Generated by site/build.mjs: sends the visitor to the page in their language. -->
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Vibe Manager</title>
<link rel="canonical" href="${SITE_URL}${DEFAULT_LANG}/">
${LANGS.map(([c]) => `<link rel="alternate" hreflang="${c}" href="${SITE_URL}${c}/">`).join("\n")}
<link rel="alternate" hreflang="x-default" href="${SITE_URL}${DEFAULT_LANG}/">
<link rel="icon" type="image/png" href="assets/icon-64.png">
<script>
(function () {
  var codes = ${JSON.stringify(codes)};
  var saved; try { saved = localStorage.getItem("vm-lang"); } catch (e) {}
  var pick = codes.indexOf(saved) >= 0 ? saved : null;
  var prefs = navigator.languages || [navigator.language || "${DEFAULT_LANG}"];
  for (var i = 0; !pick && i < prefs.length; i++) {
    var p = prefs[i];
    if (codes.indexOf(p) >= 0) pick = p;
    else if (/^zh-(TW|HK|MO|Hant)/i.test(p)) pick = "zh-TW";
    else if (/^zh/i.test(p)) pick = "zh-CN";
    else if (/^pt/i.test(p)) pick = "pt-BR";
    else if (codes.indexOf(p.split("-")[0]) >= 0) pick = p.split("-")[0];
  }
  location.replace((pick || "${DEFAULT_LANG}") + "/" + location.hash);
})();
</script>
<style>
  body { margin: 0; padding: 48px 20px; font: 16px/1.6 -apple-system, "Segoe UI", system-ui, sans-serif; background: #f7f6fb; color: #1b2033; }
  @media (prefers-color-scheme: dark) { body { background: #11131f; color: #eef0fa; } }
  ul { list-style: none; padding: 0; display: flex; flex-wrap: wrap; gap: 8px 18px; }
  a { color: inherit; }
</style>
</head>
<body>
  <main>
    <h1>Vibe Manager</h1>
    <ul>
      ${links}
    </ul>
  </main>
</body>
</html>
`;
}

// ---------- Changelog ----------

function releaseNavItem(r, code) {
  return `<a href="#${releaseId(r)}"><span>${escapeHTML(version(r))}</span><small>${escapeHTML(formatDate(r.published_at, code, { day: "numeric", month: "short" }))}</small></a>`;
}

function releaseList(code, t) {
  const items = releases.map((r, i) => {
    const badges = (i === 0 ? `<span class="badge latest">${t("js.latest")}</span>` : "") +
      (r.prerelease ? `<span class="badge pre">${t("js.prerelease")}</span>` : `<span class="badge stable">${t("js.stable")}</span>`);
    const dmg = downloadURL(r);
    return `<article class="release" id="${releaseId(r)}">
        <div class="rel-head"><h2>${escapeHTML(version(r))}</h2>${badges}<time class="rel-date" datetime="${escapeAttr(r.published_at)}">${escapeHTML(formatDate(r.published_at, code))}</time></div>
        <div class="rel-body" lang="${SOURCE_LANG}" dir="ltr">${markdown(r.body || "")}</div>
        <div class="rel-actions">${dmg ? `<a class="btn btn-primary btn-sm" href="${escapeAttr(dmg)}"><svg aria-hidden="true"><use href="#i-apple"/></svg>${withVersion(t, "js.download_version", version(r))}</a>` : ""}<a class="btn btn-ghost btn-sm" href="${escapeAttr(r.html_url)}">${t("js.view_on_github")}</a></div>
      </article>`;
  });
  items.push(`<p class="cl-note">${t("js.full_history", { url: `${GH}/releases` })}</p>`);
  return items.join("\n      ");
}

function version(r) { return r.tag_name.replace(/^v/, ""); }
function releaseId(r) { return "v" + version(r).replace(/[^a-z0-9]/gi, "-"); }
function downloadURL(r) {
  const dmg = (r.assets || []).find((a) => /\.dmg$/.test(a.name));
  return dmg && dmg.browser_download_url;
}
function formatDate(iso, code, options = { day: "numeric", month: "long", year: "numeric" }) {
  return new Date(iso).toLocaleDateString(code, options);
}

// The subset of Markdown release notes use: headings, bullet lists, paragraphs, bold, code, links.
function markdown(text) {
  const out = [];
  let list = false;
  for (const line of text.replace(/\r/g, "").split("\n")) {
    const item = line.match(/^\s*[-*]\s+(.*)/);
    if (item) {
      if (!list) { out.push("<ul>"); list = true; }
      out.push(`<li>${inline(item[1])}</li>`);
      continue;
    }
    if (list) { out.push("</ul>"); list = false; }
    const heading = line.match(/^#{1,4}\s+(.*)/);
    if (heading) out.push(`<h3>${inline(heading[1])}</h3>`);
    else if (line.trim()) out.push(`<p>${inline(line)}</p>`);
  }
  if (list) out.push("</ul>");
  return out.join("");
}

function inline(s) {
  return escapeHTML(s)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    // A quote never enters a URL, so a link cannot leave its href.
    .replace(/\[([^\]]+)\]\((https?:[^)\s"]+)\)/g, '<a href="$2">$1</a>')
    .replace(/(^|[\s(])(https?:\/\/[^\s)<"]+)/g, '$1<a href="$2">$2</a>')
    .replace(/(^|[\s(,])#(\d+)\b/g, `$1<a href="${GH}/issues/$2">#$2</a>`);
}

// ---------- Helpers ----------

function issueURL(kind, t) {
  const label = kind === "bug" ? "bug" : "enhancement";
  return `${GH}/issues/new?title=${encodeURIComponent(t(`js.issue.${kind}.title`))}&labels=${label}&body=${encodeURIComponent(t(`js.issue.${kind}.body`))}`;
}
// A version number keeps its own direction inside right-to-left text.
function withVersion(t, key, v) {
  return escapeHTML(t(key, { v: "\u0000" })).replace("\u0000", `<bdi>${escapeHTML(v)}</bdi>`);
}
function strip(html) { return html.replace(/<[^>]+>/g, "").replace(/&nbsp;/g, " ").replace(/\s+/g, " ").trim(); }
function escapeHTML(s) { return String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]); }
function escapeAttr(s) { return escapeHTML(s).replace(/"/g, "&quot;"); }
