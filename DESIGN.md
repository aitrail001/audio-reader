---
name: AudioReader
description: Paper-and-terracotta reading desk for Mac and iPad, extended to the operator ledger.
colors:
  terracotta: "#B8521F"
  terracotta-ink: "#7A3413"
  terracotta-wash: "rgba(184, 82, 31, 0.16)"
  gold: "#B7802E"
  gold-soft: "rgba(232, 184, 110, 0.22)"
  ink-on-gold: "#241A0F"
  bg: "#F7F2E8"
  panel: "#FEFAF4"
  panel2: "#EDE6D9"
  ink: "#291F17"
  dim: "#6B5E52"
  mute: "#8C8070"
  line: "rgba(0, 0, 0, 0.08)"
  ok: "#2F6B3A"
  warn: "#8A5A12"
  bad: "#9B2C1A"
typography:
  display:
    fontFamily: "New York, Palatino, Georgia, ui-serif"
    fontSize: "largeTitle"
    fontWeight: 600
  headline:
    fontFamily: "New York, Palatino, Georgia, ui-serif"
    fontSize: "22pt"
    fontWeight: 400
  title:
    fontFamily: "San Francisco, ui-sans-serif, system-ui"
    fontSize: "subheadline"
    fontWeight: 500
  body:
    fontFamily: "San Francisco, ui-sans-serif, system-ui"
    fontSize: "body"
    fontWeight: 400
  label:
    fontFamily: "San Francisco, ui-sans-serif, system-ui"
    fontSize: "footnote"
    fontWeight: 400
  operator-wordmark:
    fontFamily: "New York, Iowan Old Style, Palatino, Georgia, Times New Roman, serif"
    fontSize: "1.35rem"
    fontWeight: 600
    lineHeight: 1.1
    letterSpacing: "-0.02em"
  operator-stage:
    fontFamily: "SF Pro Text, Segoe UI, system-ui, sans-serif"
    fontSize: "1.5rem"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "-0.02em"
rounded:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  pill: "999px"
spacing:
  xs: "4px"
  sm: "6px"
  md: "8px"
  lg: "12px"
  xl: "16px"
  xxl: "24px"
  control: "44px"
components:
  button-primary:
    backgroundColor: "{colors.terracotta}"
    textColor: "{colors.panel}"
    rounded: "{rounded.md}"
    padding: "10px 16px"
    height: "{spacing.control}"
  button-study:
    backgroundColor: "{colors.gold}"
    textColor: "{colors.ink-on-gold}"
    rounded: "{rounded.md}"
    padding: "10px 16px"
    height: "{spacing.control}"
  button-secondary:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "10px 16px"
    height: "{spacing.control}"
  input-field:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.ink}"
    rounded: "{rounded.sm}"
    padding: "8px 10px"
    height: "{spacing.control}"
  chip-filter:
    backgroundColor: "{colors.panel2}"
    textColor: "{colors.dim}"
    rounded: "{rounded.pill}"
    padding: "6px 10px"
    typography: "{typography.label}"
  chip-filter-on:
    backgroundColor: "{colors.gold-soft}"
    textColor: "{colors.gold}"
    rounded: "{rounded.pill}"
    padding: "6px 10px"
    typography: "{typography.label}"
  card-book:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "12px"
  form-settings:
    backgroundColor: "{colors.bg}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
  form-settings-row:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "12px 16px"
    height: "{spacing.control}"
  nav-destination:
    backgroundColor: "{colors.bg}"
    textColor: "{colors.ink}"
  warning-callout:
    backgroundColor: "{colors.gold-soft}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "10px"
  button-operator-primary:
    backgroundColor: "{colors.terracotta}"
    textColor: "{colors.panel}"
    rounded: "{rounded.sm}"
    padding: "0 16px"
    height: "{spacing.control}"
  button-operator-ghost:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.ink}"
    rounded: "{rounded.sm}"
    padding: "0 16px"
    height: "{spacing.control}"
  button-operator-danger:
    backgroundColor: "transparent"
    textColor: "{colors.bad}"
    rounded: "{rounded.sm}"
    padding: "0 16px"
    height: "{spacing.control}"
  nav-operator-rail:
    backgroundColor: "{colors.panel2}"
    textColor: "{colors.ink}"
    rounded: "{rounded.sm}"
    height: "{spacing.control}"
  nav-operator-rail-current:
    backgroundColor: "{colors.terracotta-wash}"
    textColor: "{colors.terracotta-ink}"
    rounded: "{rounded.sm}"
    height: "{spacing.control}"
  ledger-sheet:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "16px 18px"
  table-operator:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
  pill-ok:
    backgroundColor: "{colors.gold}"
    textColor: "{colors.ink-on-gold}"
    rounded: "{rounded.pill}"
    padding: "2px 9px"
  pill-warn:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.warn}"
    rounded: "{rounded.pill}"
    padding: "2px 9px"
  pill-bad:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.bad}"
    rounded: "{rounded.pill}"
    padding: "2px 9px"
  health-pip:
    backgroundColor: "{colors.bg}"
    textColor: "{colors.dim}"
  gate-sign-in:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.ink}"
    rounded: "{rounded.lg}"
    padding: "27px 25px 29px"
  form-runtime:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "16px 18px"
---

# Design System: AudioReader

## Overview

**Creative North Star: "The Paper Desk"**

AudioReader is a bound-book desk, not a media dashboard. Warm paper fills the window; terracotta is the only chrome accent; gold is the bookmark that marks what is ready, playing, or saved. The product is a dedicated reading tool: calm, book-focused, and thoughtful. Native Mac and iPad use SwiftUI controls; the operator console is the same desk, drawn as a paper ledger in the browser — not a second brand and not a SaaS metrics product.

Settings is a first-class destination beside Library, Player, and Words. It is a grouped Form page with a large title, Account at the top, Save in the trailing toolbar, and version as the last row — not a modal that interrupts the book. The Form hides the OS grouped-list fill and sits on Laid Paper with Hot-Pressed Sheet rows, the same paper stack as Library and the reader. macOS and iPadOS are two presentations of one desk: shared Palette, shared type roles, shared destinations; only column chrome and toolbar placement change.

The operator console (`server/apps/admin-web`) is a third presentation of that desk. A signed-in operator sees global health in the paper top bar, grouped destinations in the left rail, and an incident-first Desk that prioritizes degraded dependencies, failed jobs, quota pressure, configuration drift, and recent errors. A contextual mutation bar appears only when an action needs a reason and shows the before/after summary before commit. Operational tables use the same tonal paper and hairlines — not charts, glass, neon, ruled paper, or simulated grain.

The world rejects cramped desktop chrome transplanted onto iPad, decorative AI-dashboard styling, and dense configuration competing with the reading surface. Native Settings stay native SwiftUI; the operator console may use HTML form chrome on paper, but it must not impersonate a metrics cloud.

**Key Characteristics:**
- Paper stack: `bg` page, `panel` card, `panel2` inset — never a white/gray OS default as the brand ground
- Settings Form paints that stack (`scrollContentBackground(.hidden)`, `Palette.bg` page, `Palette.panel` rows)
- Terracotta tint for app chrome and primary actions; gold for status, study, and playback-on
- Native grouped Form for Settings; sidebar + split columns for destinations
- System text styles for chrome and Settings; New York (or Georgia / Palatino) for books
- SF Symbols for status and navigation on native; 44-point control floors on interactive rows
- Tonal layering and hairline `line` strokes instead of offset drop shadows
- Operator console uses flat `bg` / `panel` / `panel2` layers and hairlines; New York is the wordmark only
- Operator Desk is incident-first; ready/ok is ink-on-gold, not a green chip

## Colors

`Palette` in `Theme.swift` is the only color source for native surfaces. Each native token is a paired light/dark sRGB color. Light values in the frontmatter are the canonical paper-desk reading surface; dark counterparts live in `.impeccable/design.json`. The operator console maps those same light hexes onto CSS custom properties and adds ledger inks (`terracotta-ink`, `ok`, `warn`, `bad`) used only on the web console.

### Primary
- **Fired Terracotta** (`terracotta`): App `.tint`, bordered-prominent library and account actions, iPad sidebar selection wash at 16% opacity (`terracotta-wash`), playback-chrome emphasis, job-count badge, operator primary buttons (Save runtime config, Sign in, Save policy). The clay mark of the desk — used for doing, not for decorating.
- **Terracotta Ink** (`terracotta-ink`): Operator selected-rail labels and in-page links. Dark scheme uses lamp gold for this role so selected type stays readable on paper-dark.

### Secondary
- **Lamp Gold** (`gold`): Ready/transcribed checkmarks, connection-ready labels, selected chapter chips, study/review prominent buttons, playback-loop and assistant-on glyphs, vocabulary category tags, successful Settings save, operator ok pills, and live health-pip dots. The bookmark, not the brand stripe.
- **Lamp Gold Wash** (`gold-soft`): Selected filters, legal and migration callouts, reader notices, vocabulary “already saved” banners, Account error callouts, operator selected table rows and preview banners.
- **Ink on Gold** (`ink-on-gold`): Text drawn on filled gold buttons and on operator ok pills so the bookmark stays readable.

### Tertiary
- **Forest Ok** (`ok`): Operator success copy (`.status-line`) only. Not a fill for ready pills.
- **Amber Warn** (`warn`): Operator degraded pips, missing-secret pills, and warn-pill type. Dark scheme aliases this to lamp gold.
- **Ledger Red** (`bad`): Operator alerts, danger/confirm-armed buttons, and failed-state pills. Native Sign out stays system `Color.red`, not this token.

### Neutral
- **Laid Paper** (`bg`): Window and page ground for Library, Player, Vocabulary, and Settings — including the Settings Form after the OS grouped fill is hidden. Operator `body` and expanded table rows sit on the same flat tone.
- **Hot-Pressed Sheet** (`panel`): Book cards, player chrome tray, every Settings grouped-form row (`listRowBackground(Palette.panel)`), operator ledgers, data tables, fields, the top bar, and the sign-in gate.
- **Deckled Inset** (`panel2`): Cover placeholders, unselected chips, search field fill, unselected chapter chips, operator rail, table headers, and idle pills.
- **Walnut Ink** (`ink`): Primary text, Settings row labels, book titles, operator body copy.
- **Walnut Dim** (`dim`): Secondary copy, authors, connection-not-ready, Settings helpers, failed save feedback, operator ledes, pip labels, field labels. Not system `.secondary` when Palette already owns the row.
- **Walnut Mute** (`mute`): Decorative icons, disabled states, and large nonessential marks only. Small metadata and status copy must use a contrast-compliant secondary text token at 4.5:1 or better.
- **Hairline** (`line`): 1pt strokes and dividers (`Divider().overlay(Palette.line)`). Selected book cards replace it with a 2pt gold stroke. Operator rules, table lines, and field borders use the same hairline role.

### Named Rules
**The Terracotta Tint Rule.** `.tint(Palette.terracotta)` on the split root and on Settings. Primary bordered-prominent buttons are terracotta. Gold is never the app tint. Operator committing actions (Save runtime config, Sign in, Save policy) are terracotta fills.

**The Bookmark Gold Rule.** Gold means ready, on, saved, or study — checkmarks, selected chips, review actions, playback-active glyphs, operator ok pills, live health pips. Do not paint large surfaces gold.

**The Ink-on-Gold Ready Rule.** Operator ready/ok/enabled/set pills are gold fill with `ink-on-gold` type. Never fill those pills with `ok` green.

**The Paper Stack Rule.** Screens sit on `bg`. Cards and chrome sit on `panel`. Insets, placeholders, and unselected chips sit on `panel2`. Do not introduce a fourth ground.

**The Paper Form Rule.** Settings Form is grouped, then the OS grouped-list fill is hidden. The page is `Palette.bg`; every section uses `listRowBackground(Palette.panel)`. Do not leave Settings on system grouped gray or grouped-dark fill.

## Typography

**Display Font:** New York (system serif; reader may switch to Georgia, Palatino, or San Francisco)
**Body Font:** San Francisco (system `.body`, `.subheadline`, `.footnote`, `.headline`, `.caption`); operator chrome is SF Pro Text / Segoe UI / system-ui at 15px / 1.45
**Label/Mono Font:** San Francisco monospaced (slider percentages, clocks, speed); operator IDs, JSON, and hashes are ui-monospace / SF Mono / Menlo at 0.78–0.82rem in `dim`

**Character:** The book speaks in a literary serif; the desk speaks in the system UI face. Settings never invents a display face — it uses Dynamic Type system styles. The reader column scales New York from a 16–34 pt width-aware ramp (`ReaderType`), with assistant gloss clamped 11–15 pt. On the operator console, New York appears only in the AudioReader wordmark; stage titles, the sign-in heading, labels, and tables stay San Francisco.

### Hierarchy
- **Display** (semibold system serif, SwiftUI `.largeTitle`): iPad book-detail title only. Settings uses the platform large navigation title in San Francisco, not New York. Operator wordmark is New York 1.35rem / 600 / −0.02em tracking, with a 0.75rem San Francisco subtitle in `dim`.
- **Headline** (regular 22 pt system serif; semibold 14–20 pt serif for cards and vocab headwords): macOS Vocabulary page title; library book titles (14 pt semibold serif); vocab headwords (20 pt semibold serif).
- **Title** (medium subheadline, San Francisco): Settings `settingRow` labels; Form section headers; connection status. Operator stage titles are 1.5rem / 600 San Francisco (−0.02em); ledger headings are 0.95rem / 600.
- **Body** (regular system `.body`): Account session copy, sign-in controls, Settings helpers that sit in Account, grouped-form values. Operator body is 15px / 1.45 walnut ink; ledes cap at 68ch in `dim`.
- **Label** (footnote / caption / 11–12 pt): Settings helpers (`.footnote` + `Palette.dim`, or `Palette.mute` when muted), slider readouts (11 pt monospaced), library meta (11 pt), chips (12 pt medium). Operator field labels are 0.84rem / 500 `dim`; table headers and idle pills are 0.75rem / 600 or 500 `dim`.

### Named Rules
**The Two Voices Rule.** Serif is for books, headwords, and literary titles. San Francisco system styles are for Settings, Account, toolbars, and chrome. Do not set Settings labels in New York.

**The Wordmark-Only Serif Rule.** On the operator console, New York is the AudioReader wordmark only. Stage titles, gate headings, rail destinations, and form labels stay San Francisco.

**The System Settings Type Rule.** Settings and Account use SwiftUI text styles (`.body`, `.subheadline.weight(.medium)`, `.footnote`) so Dynamic Type and the grouped Form stay native. Hard-coded point sizes belong to the reader and to compact chrome, not to the Settings page.

## Layout

macOS and iPad share four destinations: Library, Player, Words, Settings (`AppTab`). Settings is a page, not a sheet.

**macOS.** `NavigationSplitView` with a 220–300 pt sidebar. Library, Now Reading, Words, and Settings are the stable primary destinations; sources and books are subordinate Library content. `⌘1`, `⌘2`, `⌘3`, and `⌘,` navigate without moving focus through a segmented toolbar. The reader toolbar keeps only current-task actions. Lookup and assistant content use the native inspector while iPad retains its touch-resizable split.

**iPad.** `NavigationSplitView` `.prominentDetail` for Library/Reader; Settings uses its own split (sidebar + detail). Sidebar 180–300 pt (ideal 220) lists Library sources, Study → Vocabulary, then Settings (`gearshape`) in its own section. Content column 200–560 pt (ideal 260). Settings mode is `.doubleColumn`: Settings occupies the detail, and background-job toolbar ownership moves to detail (`IPadBackgroundJobsToolbarPlacement`). Vocabulary and focused reading collapse to `.detailOnly`. Sidebar rows are 44 pt tall; selected row uses terracotta at 16% opacity.

**Settings page.** `Form` + `.formStyle(.grouped)` + `.scrollContentBackground(.hidden)` + `.background(Palette.bg)`, tinted terracotta. Each section, including Version, uses `.listRowBackground(Palette.panel)`. Section order is fixed: Account, Appearance, Apple Dictionary, Languages, LLM provider, then a trailing section whose last durable row is Version. Trailing toolbar: Revert (`.cancellationAction`) and Save Settings (`.confirmationAction`, default keyboard shortcut), both disabled until dirty. iPad uses a large navigation title and hides the back button.

**Library.** Adaptive cover grid, 180–220 pt cards, 16 pt column gutter, 24 pt row gutter, 24 pt page padding. Selected book docks a chapter strip in a bottom safe-area inset.

**Reader.** Split keeps ~62% for text and ~38% for lookup, lookup floor 220 pt, preferred text 320 pt, absolute text 200 pt. iPad splitter hit target is 44 pt; macOS splitter is 8 pt visual.

**Words and learning.** The page begins with one opaque `panel` learning ledger, not a dashboard wall. A compact horizontally scrollable summary reports due, new, learning, today, study-day streak, and 30-day retention with hairline separators. The primary terracotta action starts due learning cards, due mature reviews, then at most 20 new cards. Seven-day due forecast and per-book progress use `panel2` insets. Calendar, not flame, represents study continuity; there are no points, leagues, or celebratory motion. Review advancement is visible only after schedule and immutable history persist together.

**Sync status.** Account status names the active phase and entity instead of showing a generic spinner. It may add batch/item progress and pending, applied, or conflict counts, but never cycles rapidly through decorative messages. The same shared status view and VoiceOver summary appear on macOS and iPadOS. Completed and failed states retain the last meaningful entity so the reader knows what converged or needs retrying.

**Rhythm.** Recurring padding is 6 (label-to-control), 8, 10, 12, 16, 24. Interactive rows and Account buttons use a 44 pt minimum height. Reader playback chrome is denser on iPad (16 / 4 / 6) than on Mac (24 / 14 / 14).

**Operator console.** Shell is a top bar plus a 16rem grouped rail and a fluid stage. The rail groups Desk; People (Users, Access, Privacy); AI (Policies, Cache); Delivery (Jobs, Flags, Quotas); and Observe (Metrics, Activity, Trace, Audit). Every destination is at least 44 px and persists in the URL with its filters. The Desk opens on incidents, with configuration secondary. Each destination owns independent loading, stale-data, retry, filter, and cursor state. At compact widths the rail becomes a bounded 44 px destination selector so the stage remains primary. A contextual mutation bar is blank by default, requires five characters, summarizes before/after, and clears after success.

**Operator Metrics.** Metrics is an evidence page, not the default landing page. It uses a single summary ledger, a restrained accessible trend line, an anomaly watch, and tabular distributions for coarse geography, language, reader level, platform/version, opaque content, feature, and outcome. Filters persist in the URL. Charts always have labelled table-equivalent values and never rely on color alone. Copy states that identifiers are pseudonymous, cohorts below the privacy threshold are grouped, and precise location and reading text are not collected.

### Named Rules
**The First-Class Settings Rule.** Settings is a sidebar/tab destination equal to Library and Words. Do not present it as a modal over the reader.

**The Account-to-Version Rule.** Settings scans Account → Appearance → Dictionary → Languages → LLM → Version. Save lives in the toolbar, not as a row inside the Form.

**The One Toolbar Owner Rule.** On iPad, stateful toolbar actions belong to exactly one visible column (content or detail), never both.

**The Desk-First Rule.** The operator stage opens on actionable incidents and degradation, then configuration. Do not open on metrics or render every concern as an equal card.

**The Contextual Mutation Rule.** A mutation bar appears with the action it governs, starts blank, requires a specific five-character reason, previews before/after, and clears after success. Destructive or high-impact changes also require explicit confirmation.

## Elevation & Depth

The desk is flat paper. Depth comes from stacking `bg` / `panel` / `panel2`, from 1 pt `line` (or 2 pt gold when a book card is selected), and from system materials — `.ultraThinMaterial` on the library chapter strip, `.regularMaterial` on scan progress and iPad import overlays. There is no offset drop-shadow vocabulary.

Legal and migration warnings, reader notices, and gold-soft banners are tonal veils, not lifted cards. Settings grouped rows are paper `panel` sheets on a `bg` page, not the OS inset-grouped fill.

The operator page uses opaque flat `bg`, `panel`, and `panel2` layers. It does not tile `paper-grain.svg`, draw ruled gradients, or create wide shadow halos. Live ok pips may pulse a restrained concentric gold ring as a health signal; `prefers-reduced-motion: reduce` removes that pulse and every nonessential transition.

### Named Rules
**The Hairline Rule.** Separators are `Palette.line`. Do not add hard offset shadows. Selection is a gold stroke or a terracotta wash, not a drop shadow.

**The Live Pip Rule.** Operator ok pips may pulse a concentric gold ring. Do not reuse that ring as card elevation.

## Shapes

Continuous rounded rectangles at 12 pt own covers, book cards, warning callouts, operator ledgers, and data-table frames. 8 pt owns search fields, chapter chips, iPad list covers, operator fields, rail destinations, and operator buttons. 4 pt owns macOS sidebar 32×32 thumbs and skeleton bars. Capsules own filter chips, category tags, the job-count badge, and operator status pills. Scan overlays and the operator sign-in gate use 16 pt. Native `.roundedBorder` text fields and system bordered-prominent buttons keep platform corner language; do not restyle them into pills unless they are chips.

Cover placeholders are 2:3 rectangles. iPad list covers are 48×70; book detail cover is 140×204. Health pips are 0.55rem circles.

### Named Rules
**The Native Control Shape Rule.** Settings fields, steppers, segmented pickers, and bordered buttons keep SwiftUI shapes. Custom radii apply to paper cards, chips, covers, and callouts — not to a restyled Form. Operator HTML controls use 8 px fields and 12 px ledgers; they do not restyle native Settings.

## Components

Native, restrained, and labeled. Primary actions are terracotta; study/status actions are gold; everything else is borderless, bordered, or plain list. The operator console repeats those roles in HTML: terracotta fill, gold ready pills, ghost sheets, ledger-red danger.

### Buttons
- **Shape:** Platform bordered / bordered-prominent corners; custom paper clips use 12 pt continuous. Operator buttons are 8 px (`rounded.sm`), 44 px min height, 0 1rem padding.
- **Primary:** `.borderedProminent` + terracotta. Used for Open player, Add EPUB, Send email sign-in code, and other committing desk actions. Minimum height 44 pt in Account and Settings. Operator: fill terracotta, type `panel`; hover mixes 12% black; active uses `terracotta-ink`. Labels include Save runtime config, Sign in, Send sign-in code, Save policy.
- **Study:** `.borderedProminent` + gold fill + `ink-on-gold` label (macOS “Choose review”). Gold-tinted bordered for learn-list on.
- **Secondary / Ghost:** `.bordered` or `.plain` on ink. OAuth sign-in rows are tinted terracotta Labels at 44 pt. Operator ghost: `panel` fill, 1 px `line` stroke, `panel2` hover (Refresh, Apply, Load more, Use token, clear-secret actions).
- **Danger:** Operator only. Transparent fill, `bad` type, stroke mixed from `bad` and `line`. Armed confirmations (Confirm suspend, Confirm revoke) switch to this style.
- **Sign out:** Native: full-width plain live button, `.body.weight(.medium)`, `role: .destructive`, `.buttonStyle(.plain)`, `.foregroundStyle(Color.red)`, min height 44 pt. System red, not a Palette token, never terracotta. Confirm with the Sign out alert. Revoke stays a body control that presents a destructive alert. Operator: plain `#C62828` text, 8 px corners, 8% red wash on hover — still not terracotta or gold.
- **Toolbar:** Text actions “Revert” and “Save Settings”; SF Symbol labels for Import, Library folder, destinations. Operator session uses ghost Refresh beside Sign out.

### Chips
- **Style:** Capsule, 12 pt medium, 10×6 padding. Off: `panel2` fill, dim text. On: `gold-soft` fill, gold text. Chapter chips are 8 pt rounded rects with the same gold-soft / panel2 pair and a gold or hairline stroke for transcribed vs not.

### Cards / Containers
- **Corner Style:** 12 pt continuous.
- **Background:** `panel` with `panel2` 2:3 cover well.
- **Shadow Strategy:** none; 1 pt `line` stroke, 2 pt gold when selected.
- **Internal Padding:** 12 pt on the card, 8 pt under the cover.
- **Vocab cards:** Clear list rows on `bg`, 8/16 insets, serif headword, gold capsule category.
- **Operator ledger:** `panel` sheet, 1 px `line`, 12 px corners, 1rem / 1.15rem padding. Groups Service and Runtime configuration on Desk, and the metrics snapshot.
- **Operator gate:** 16 px corners, max-width 28rem, centered with 3.5rem top margin.

### Inputs / Fields
- **Style:** SwiftUI `TextField` / `SecureField` `.textFieldStyle(.roundedBorder)` in Settings; plain field on `panel2` 8 pt rounded search in Vocabulary. Field chrome stays native (including the OS field fill); the paper is the `panel` row around them. Operator fields: `panel` fill, 1 px `line`, 8 px corners, 44 px min height, terracotta caret. Textareas (GCS JSON) are mono 0.82rem, min-height 7.5rem.
- **Focus:** Platform focus ring. Operator `:focus-visible` is a 2 px terracotta outline, offset 2 px. Do not add a custom glow.
- **API keys:** Replacement-only SecureField; never prefilled. “Remove key” is an explicit control. Helpers stay `.footnote` + `Palette.dim`. Operator Qwen / GCS / Turnstile secrets are blank-to-keep password fields with separate ghost clear actions.
- **Disabled:** Save/Revert disabled until dirty; retrieve-model buttons disabled while loading. Operator mutations disabled until the reason dock is ready, at 45% opacity.

### Navigation
- **macOS:** Stable sidebar destinations (Library `books.vertical`, Now Reading `text.alignleft`, Words `bookmark`, Settings `gearshape`) above subordinate sources and books. The toolbar is reserved for the active task.
- **iPad:** Sidebar sections Library / Study / Settings. Selected row terracotta wash. Settings uses large title; Vocabulary and Reader stay `.inline`.
- **Settings toolbar:** Revert leading/cancellation, Save Settings trailing/confirmation.
- **Operator rail:** 16rem `panel2` column grouped by Desk, People, AI, Delivery, and Observe. Destinations are 44 px, 8 px corners, left-aligned, normal case, and keyboard reachable. Current page: `terracotta-wash` + `terracotta-ink` + 600. Compact: one bounded destination selector rather than a 14-item wrapped block.

### Settings grouped Form (signature)
A native grouped settings page on paper. Hide the OS scroll background; paint `Palette.bg` behind the Form and `Palette.panel` on every row. Each control sits under a medium-subheadline ink label with 6 pt gap and 44 pt control floor. Helpers are footnote + `Palette.dim` (or `Palette.mute` when muted). Connection status is an SF Symbol `Label`: `checkmark.circle.fill` + gold when ready, `exclamationmark.circle` + dim when not. Unofficial provider logins use a 12 pt gold-soft callout with `exclamationmark.triangle.fill` in gold and a footnote link. Version is the last row; save confirmation is a gold check Label in that same trailing section (dim triangle + dim copy on failure).

### Connection status
Gold check for ready; dim warning circle for blocked. Never terracotta for status.

### Operator health pips (signature)
Top-bar live dots, 0.78rem `dim` labels. Idle fill is `mute`. Ok fill is gold and pulses. Degraded/unavailable fill is `warn`. Health is public; the rest of the console waits on an admin JWT.

### Operator status pills (signature)
Capsule 0.75rem / 500. Ok (ok, active, enabled, succeeded, set): gold fill, `ink-on-gold` type. Warn (disabled, missing, degraded): `warn` type on a 16% warn wash. Bad (failed, dead_letter, deleted, purged): `bad` type on a 12% bad wash. Idle: `panel2` + `dim`.

### Operator data table (signature)
`panel` frame, 12 px corners, hairline. Headers on `panel2`, 0.75rem / 600 `dim`. Cells 0.7rem / 0.85rem. Selected row `gold-soft`; expanded detail row `bg` with an 8rem / 1fr definition list. Tabular numbers. Mono IDs under the primary cell. Row actions wrap; compact confirms may drop to 2.25rem height.

### Operator runtime form (signature)
Desk’s second ledger. Two-column Qwen URL/model, then replacement secrets, then terracotta Save runtime config plus ghost clears. Bootstrap secrets follow as a lined service table of set/missing pills. This is Operate’s grouped form: paper sheet, code-led fields, committing clay — not a Worker YAML editor and not native Settings.

## Do's and Don'ts

### Do:
- **Do** treat Settings as a first-class destination with grouped Form, large title, Account first, Version last, and Save in the trailing toolbar.
- **Do** hide the Settings Form scroll background and stack paper as `bg` page → `panel` rows (`panel2` only for insets elsewhere).
- **Do** tint the app and primary buttons terracotta; use gold only as the bookmark (ready, on, study, selected chip, operator ok pill, live pip).
- **Do** use system text styles in Settings/Account and New York (or the reader’s chosen serif) for books and headwords.
- **Do** keep 44 pt minimum interactive height on Settings rows, Account buttons, iPad sidebar rows, and operator destinations/fields/primary actions.
- **Do** ship the same destinations and Palette on macOS and iPadOS; change only split columns and toolbar placement.
- **Do** open the operator console on Desk with incidents, failed jobs, quota pressure, drift, and recent request-linked errors first.
- **Do** show a contextual blank change reason with before/after summary and require five characters before mutations.
- **Do** paint operator ok/enabled/set as gold + `ink-on-gold`; keep New York on the operator wordmark only.
- **Do** use flat tonal paper layers, hairlines, labelled keyboard-focusable tables, and 44 px targets on the operator page.

### Don't:
- **Don't** present Settings as a sheet, popover, or inspector over the reader.
- **Don't** leave Settings on the OS grouped-list fill, or invent a fourth paper ground for native field chrome.
- **Don't** restyle native Settings into a web form kit or AI-dashboard cards. The operator console is the Paper Desk ledger, not a substitute Settings page and not a SaaS metrics dashboard.
- **Don't** make gold the app tint or flood a screen with terracotta.
- **Don't** add offset drop shadows.
- **Don't** tile simulated grain, draw ruled-paper gradients, use wide shadow halos, or turn group labels into decorative uppercase micro-copy.
- **Don't** set Settings labels in a display serif or invent a third type family beyond system UI, the reader serif choice, and monospaced metrics.
- **Don't** set operator stage titles, gate headings, or rail labels in New York.
- **Don't** fill ready/ok pills with `ok` green.
- **Don't** duplicate stateful toolbar actions into two iPad columns.
- **Don't** preload API keys into fields or style credential rows as a dashboard widget.
- **Don't** restyle Sign out into a terracotta or gold fill; native stays plain `Color.red`, operator stays plain `#C62828`.
