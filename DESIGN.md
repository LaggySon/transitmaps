# Laggish design guide

Version 1.0.0 (2026-10-14). See CHANGELOG.md.

A design language for web apps: internal tools, dashboards, admin panels, customer-facing products, settings and account pages, and documentation. It looks like a well-made datasheet: hairline rules, small uppercase labels, monospaced values, flat surfaces, and color only where something has a state.

Its purpose: every web app built with this guide has the same look and feel, so that a user who knows one of the apps recognizes the others at once. The rules come from a job-monitoring console (the reference app) and are written here in a general form.

The guide is for coding agents. Every rule is written so an agent can apply it, and so a reviewer can check whether it was applied. The CSS blocks are normative: copy them, do not retype the values.

## 0. Instructions for the agent

### 0.1 Scope

The guide covers the app's own interface: every page that a user of the app works in (lists, forms, settings, control rooms, dashboards, docs).

It does not cover output that the app makes for another audience: broadcast overlays, generated documents and reports for customers, emails, embeddable widgets, slides, printed labels. That output has its own design and its own brand. Do not load `components.css` into it, and do not apply these rules to it. If the output shares a CSS bundle with the app, put `data-surface="output"` on the output layout's `<html>`. The tokens and the base rules then leave that page alone. When the app shows a preview of its output, the frame around the preview follows this guide (section 7.29) and the output inside does not.

### 0.2 Conflicting project instructions

Some projects carry generic design instructions from a generator or a template, for example "subtle micro-interactions", "smooth page transitions", "visually stunning", "always use the icon component", or a component library theme. For the app's own interface, this guide replaces them. When a project file conflicts with this guide, follow this guide, tell the user which lines conflict, and offer to replace them with a pointer to this file.

### 0.3 Steps

1. Read this whole file before you write or change any UI.
2. Copy `tokens.css` (section 2) and `components.css` (appendix A) into the project.
3. Know the two layers of this guide:
   - **Fixed.** Every app follows these, so all apps look like one family: colors, fonts, type roles, shape, borders, motion, the state system, the page shell (section 5.2), the component look, words, data formats, interaction rules, and accessibility (sections 2 to 4, 5.2, 5.8, and 6 to 14). Do not change color, font, radius, or motion tokens.
   - **Free.** Each app chooses these: the layout of the content inside the shell, the page structure, which components it uses, and the density (section 5). The defaults in section 5 are the reference app's layout and density; start from them. Change the density only for a reason that section 5.1 names, through the adjustable tokens in `ui-local.css`, never by editing `components.css`.
4. Build every screen from the components in section 7. If you need something new, build it from the tokens and the fixed rules. Put its CSS in `ui-local.css` (or `ui-local.module.css`), which loads after `components.css`.
5. When this guide does not cover a decision, pick the option that is flatter, quieter, uses fewer colors, and shows more of the user's content.
6. Before you report a UI task as done, go through the checklist in section 16. It includes the contrast audit in appendix B, run in light and in dark mode.

## 1. Character

A person opens the app to do a task or to check something. The first screen shows that task or that content. The interface stays out of the way: it is precise, static, and grayscale, and it uses a hue only to say that something succeeded, failed, is in progress, or needs attention.

### Principles

1. **Content first.** The first screen shows the user's own content or the task at hand. There is no hero banner, no illustration, no welcome text, and no marketing copy, on any page, including sign-in.
2. **Flat and static.** Use 1px lines and 2px corners. Use no shadows, no gradients, and no movement. A hover changes a color or an underline. Nothing moves or changes size.
3. **Color means state.** The chrome is grayscale. A hue appears only to show a state, a link, or keyboard focus. Every colored state also has a word, a letter, or a glyph.
4. **Values are monospaced.** IDs, codes, counts and amounts in tables, sizes, timestamps, paths, versions, and input values use the mono face. Numbers inside a sentence and big display numbers (stat, hero metric) use the sans face.
5. **Compact by default.** The default density is the reference app's density: 28px controls, 32px table rows, 13.6px body text. An app changes it only when its users need it (section 5.1). Colors, type, shape, and the shell stay the same at every density.
6. **The UI says why.** A disabled control explains itself. An empty state says what to do. An error names what failed and gives a way to recover.
7. **State survives a refresh.** Filters, sort, tabs, and page live in the URL. Background updates never blank the screen.

### What this design language is not

- No cards with drop shadows, no glass, no blur, no gradients (two exceptions: the hatch pattern for "no data" and the checkerboard behind a transparent preview, section 6).
- No rounded pills for buttons or inputs. The radius is 2px everywhere. Only dots are round.
- No icon library and no emoji. Section 9 lists the glyphs.
- No spinners, no skeleton shimmer, no pulsing, no slide-in panels, no toasts.
- No color for decoration, branding, or "to make it pop".
- No marketing or landing pages. A product that needs one is out of scope for this guide.

## 2. Tokens

Put these in one global stylesheet. Each color token holds its light and its dark value in `light-dark()`. The operating-system setting picks the mode, and an optional toggle can override it (section 2.4). There is no per-component dark-mode CSS.

<!-- file: tokens.css -->
```css
/* Laggish design guide tokens. Each color is light-dark(light value, dark value).
   The OS setting picks the mode. data-theme="light" or "dark" on <html> overrides it.
   Fixed: fonts, colors, shape, motion. Adjustable per app (section 2.2): type scale, spacing, sizes. */
:root {
  color-scheme: light dark;

  /* Fonts. Load Geist and Geist Mono (section 4). */
  --font-sans: "Geist", Arial, Helvetica, sans-serif;
  --font-mono: "Geist Mono", ui-monospace, "Cascadia Mono", Consolas, monospace;

  /* Surfaces and text */
  --background: light-dark(#ffffff, #0a0a0a);
  --surface: light-dark(#ffffff, #0a0a0a);
  --foreground: light-dark(#171717, #ededed);
  --muted-foreground: light-dark(#3f3f3f, #c9c9c9);
  --label: light-dark(
    color-mix(in srgb, var(--foreground) 62%, transparent),
    color-mix(in srgb, var(--foreground) 70%, transparent)
  );
  --placeholder: var(--label);
  --border: color-mix(in srgb, var(--foreground) 18%, transparent);
  --border-input: color-mix(in srgb, var(--foreground) 30%, transparent);
  --border-strong: var(--foreground);
  --hover-surface: light-dark(
    color-mix(in srgb, var(--foreground) 6%, transparent),
    color-mix(in srgb, var(--foreground) 10%, transparent)
  );
  --backdrop: rgb(0 0 0 / 0.55);
  --hatch-a: color-mix(in srgb, var(--foreground) 4%, var(--surface));
  --hatch-b: color-mix(in srgb, var(--foreground) 11%, var(--surface));

  /* Interactive */
  --link: light-dark(#0044cc, #6db3f2);
  --focus: light-dark(#1e63b6, #228ce8);

  /* State fills: bars, tints, rails, swatches, heatmap cells */
  --success: light-dark(#90ee90, #6eeb83);
  --failure: light-dark(#f08080, #ff6b8b);
  --progress: light-dark(#26abfe, #1096ef);
  --warning: light-dark(#ffa500, #ffb84d);
  --inactive: light-dark(#b0bec5, #d0d7de);
  --skipped: light-dark(#5b8def, #7fa8ff);
  --accent: light-dark(#6e56cf, #a28bf5);

  /* State text: 4.5:1 or better on --background, on a header band, and on a badge tint */
  --success-text: light-dark(#17692f, #6eeb83);
  --failure-text: light-dark(#b3261e, #ff6b8b);
  --progress-text: light-dark(#0a5598, #5eb8ff);
  --warning-text: light-dark(#8a5200, #ffb84d);
  --inactive-text: light-dark(#5a6570, #d0d7de);
  --skipped-text: light-dark(#1f4fb8, #9bbcff);
  --accent-text: light-dark(#4f3aa8, #b9a6ff);

  /* Text on a solid state fill (not on --accent in light mode) */
  --on-fill: light-dark(#171717, #0a0a0a);
  /* Secondary text on a 45% state tint */
  --muted-on-tint: light-dark(var(--muted-foreground), var(--foreground));

  /* Shape */
  --radius: 2px;
  --rail: 3px;

  /* Type scale (adjustable as a set) */
  --text-2xs: 0.625rem;
  --text-xs: 0.7rem;
  --text-sm: 0.78rem;
  --text-md: 0.85rem;
  --text-lg: clamp(1rem, 2.2vw, 1.2rem);
  --text-xl: clamp(1.25rem, 3vw, 1.75rem);
  --text-hero: 2.4rem;

  /* Spacing scale (adjustable) */
  --space-1: 0.15rem;
  --space-2: 0.25rem;
  --space-3: 0.35rem;
  --space-4: 0.5rem;
  --space-5: 0.75rem;
  --space-6: 1rem;
  --space-7: 1.5rem;

  /* Sizes (adjustable; --control-h-sm stays at least 1.5rem) */
  --control-h: 1.75rem;
  --control-h-compact: 1.6rem;
  --control-h-sm: 1.5rem;
  --row-h: 2rem;
  --topbar-height: 2.25rem;
  --page-pad-x: clamp(0.5rem, 1.2vw, 1rem);
  --page-pad-y: 0.5rem;

  /* Motion: color changes only */
  --duration-color: 120ms;
}

/* A theme choice made by the user (section 2.4) */
:root[data-theme="light"] {
  color-scheme: light;
}

:root[data-theme="dark"] {
  color-scheme: dark;
}

/* An output surface (section 0.1) keeps the browser default, so a transparent page stays transparent */
:root[data-surface="output"] {
  color-scheme: normal;
}
```

### 2.1 What each token is for

| Token | Use it for | Never use it for |
|---|---|---|
| `--background` | Page background, popover and sticky-bar backgrounds | |
| `--surface` | Panels, cards, table headers. The base that tints mix into | |
| `--foreground` | Body text, headlines, strong borders, the primary button fill | |
| `--muted-foreground` | Secondary text: meta lines, descriptions, hints | Disabled text (use opacity on the control) |
| `--label` | Uppercase micro labels, table headers, IDs in quiet positions, chart axis text, placeholders | Text on a tinted row (section 3.3) |
| `--border` | Every hairline: panels, rows, separators | Focus |
| `--border-input` | Input and select borders at rest | |
| `--border-strong` | Emphasis lines: table header bottom, dialog and menu borders, outline buttons | Panels at rest |
| `--hover-surface` | Row hover, header bands, progress tracks, code blocks | |
| `--link`, `--focus` | Links and the focus outline. Nothing else | State |
| state fills | Bars, tints, rails, swatches, cells, dots in charts | Text |
| state `-text` | Text, thin chart marks (lines, dots, outlines), badge words | Large areas |
| `--on-fill` | Text placed on a solid state fill | Text on `--accent` in light mode |
| `--muted-on-tint` | Secondary text on a 45% state tint | |

### 2.2 Fixed and adjustable tokens

| Group | Tokens | Rule |
|---|---|---|
| Color | Every color token, including `--muted-on-tint` and `--on-fill` | Fixed |
| Fonts | `--font-sans`, `--font-mono` | Fixed |
| Shape | `--radius`, `--rail` | Fixed |
| Motion | `--duration-color` | Fixed |
| Type sizes | `--text-2xs` to `--text-hero` | Adjustable as a set. Keep the order. `--text-xs` stays at least 0.7rem (11.2px) |
| Spacing | `--space-1` to `--space-7` | Adjustable |
| Control and row sizes | `--control-h`, `--control-h-compact`, `--control-h-sm`, `--row-h`, `--topbar-height` | Adjustable. `--control-h-sm` stays at least 1.5rem (24px) |
| Page padding | `--page-pad-x`, `--page-pad-y` | Adjustable |

The components read the adjustable tokens, so an override in `ui-local.css` changes the density everywhere. Section 5.1 has an example.

### 2.3 Default sizes at a glance

| What | Default |
|---|---|
| Base text | `--text-md` (13.6px) |
| Micro label, badge, chip | `--text-xs` (11.2px), 600 or 700, uppercase. `letter-spacing` is 0.05em for labels and 0.04em for badges, chips, and buttons |
| Table cell, meta line, button | `--text-sm` (12.5px) |
| Page title | `--text-lg`, 700 |
| Stat value | `--text-xl`, 800 |
| Hero metric | `--text-hero` (38px), 800, one per page |
| Chart axis text, matrix glyph | `--text-2xs` (10px) |
| Control height | 28px default, 25.6px in toolbars and filter rows (`--compact`), 24px for row actions (`--small`) |
| Table row | 32px minimum, cell padding `0.25rem 0.45rem` |
| Corner radius | 2px for everything, except dots (round) and the inner corners of a segmented control (square) |
| Border | 1px. A state rail is 3px |

### 2.4 Light and dark mode

- The default is the system setting: `color-scheme: light dark` on `:root`, and every color token is `light-dark(light, dark)`.
- An app may offer a theme choice: a segmented control with "System", "Light", and "Dark" in the user menu or in settings. "Light" and "Dark" set `data-theme="light"` or `data-theme="dark"` on `<html>`. "System" removes the attribute. Store the choice in `localStorage` (or in the user's account) and set the attribute before the first paint, with a small script in `<head>` or from the server, so the page does not flash.
- Never write a separate dark-mode rule for a component. If a new color needs a dark value, it is a token with `light-dark()`.
- Set `<meta name="theme-color">` to `#ffffff` for light and `#0a0a0a` for dark.
- `light-dark()` needs Chrome 123, Edge 123, Firefox 120, or Safari 17.5 (all released in 2024) or later.

## 3. Color

### 3.1 State roles

Each app picks its own state words, but it maps each word to exactly one role. The role sets the color.

| Role | Fill / text tokens | Example words | Use for |
|---|---|---|---|
| success | `--success` / `--success-text` | Done, Passed, Paid, Active | Finished and good |
| failure | `--failure` / `--failure-text` | Failed, Errored, Declined, Blocked | Finished and bad, or blocked |
| progress | `--progress` / `--progress-text` | Running, Processing, Syncing, Live | Work in flight, a live connection. Also info notices |
| warning | `--warning` / `--warning-text` | Cancelled, Stale, Expiring, Overdue | A person stopped it, data is stale, it needs another try, or it needs attention soon |
| inactive | `--inactive` / `--inactive-text` | Archived, Expired, Removed | Gone, no longer live, no data |
| skipped | `--skipped` / `--skipped-text` | Skipped, Not started on purpose | Not run on purpose |
| accent | `--accent` / `--accent-text` | (none) | A grouping identity, for example a batch, a project, or a team tag. It is never a state |
| neutral | gray / `--muted-foreground` | Queued, Draft, Idle | Not started. No hue |

Rules:

1. Define the state words once, in one module (for example `src/lib/status.ts`), with the word, the role, and the precedence. Every page imports it. Two pages that show the same state show the same word.
2. When one object has several states, show the one with the highest precedence: **inactive > warning > failure > success > progress > neutral**. A person's action (warning) outranks the system's outcome.
3. An inactive object can keep its outcome. Show both words in one badge ("Archived · Failed"), and set `data-status="inactive" data-outcome="failure"` (or `"success"`). `components.css` then mixes 40% of the outcome fill into the inactive fill. Put `data-outcome` on the row, tile, or bar. The badge keeps plain `data-status="inactive"`.
4. Do not reuse a role for an unrelated meaning. If a word does not match the "Use for" column of a role, add the word to the module with the role that matches its meaning.

### 3.2 Two tiers: fill and text

Each state has a fill (light pastel in light mode, bright in dark mode) and a text color (4.5:1 or better).

- Text uses only these tokens: `--foreground`, `--muted-foreground`, `--label`, `--muted-on-tint`, a `-text` token, `--on-fill` (on a solid fill), and `--background` (on an inverted control). A fill token is never a text color.
- A mark that carries meaning and is thinner than 4px uses the `-text` tier: chart lines, chart dots, outlines, small dots in badges.
- Bars, areas, and cells may use the fill tier because a word, a letter, a legend, or a tooltip also gives the value.
- State rails and the border of a control with a text label (the danger button) also use the fill tier. A word next to them names the state, so the edge does not carry the meaning alone (WCAG 1.4.11 asks 3:1 only for marks that are needed to understand the content).
- Text on a solid fill uses `--on-fill`. The one exception is `--accent` in light mode, which is dark. For an accent fill with text, fill with `--accent-text` and write with `--background`.

### 3.3 Tint ladder

Tints are `color-mix(in srgb, <fill> N%, <base>)`. Use only these steps:

| Step | Where |
|---|---|
| 12% | Chart area under a line (as `fill-opacity: 0.12`) |
| 14% | Notice background, flag row |
| 15% | Highlighted log line |
| 25% in light mode, 16% in dark mode | Badge background |
| 45% | Whole row or tile tinted by state |
| 55% | Hover on a tinted row |

- Mix into `--surface` when the tinted element is opaque (rows, tiles, notices). Mix into `transparent` when the element sits inline on any background (badges).
- On a 45% tinted row or tile, text uses `--foreground` and `--muted-on-tint` only. `--label` and every `-text` color drop below 4.5:1 on a tint (a red word on a red row is 2.3:1 in dark mode). Use weight 600 instead of color for emphasis there.
- Badges, buttons, and progress tracks on a tinted row sit on `--surface`, not on the tint. `components.css` does this for you.

### 3.4 Chrome is grayscale

Borders, panels, headers, buttons, chips, tabs, and nav are `--foreground` at different strengths. A pressed or current control inverts: `--foreground` fill, `--background` text. The only hues outside state are `--link` and `--focus`. There is no brand color. A product name or logo appears in the top bar in `--foreground`.

### 3.5 Numbers that signal trouble

A count that shows a problem (failed payments, errored jobs) uses its `-text` color only when the count is above zero. A zero stays `--foreground`.

### 3.6 User colors

Some data is a color that a user chose: a team color, a label color, a calendar color.

- Show it as a swatch (`ui-color-swatch` with `style="--swatch: #c8102e"`) next to its value in mono ("#C8102E"). This is the one place where a color may come from data and from an inline style.
- A user color never colors the chrome: not a button, not a border, not a heading, not a row tint.
- The app's output (section 0.1) may use the user colors in any way its own design needs.

### 3.7 Extra palettes

Some views need more categories than the state roles, for example a coverage matrix or a calendar of event types. Then:

1. Try to map each category to an existing role first.
2. If that fails, add page-level tokens with a prefix (`--cov-tested`, `--cov-missing`) in a `:root` block in `ui-local.css`, each one as `light-dark(light, dark)`. Give each one a fill and, if it carries text, a `-text` value that passes the contrast audit.
3. Never write a hex value inside a component rule. Never add a component-level `@media (prefers-color-scheme)` block.

## 4. Typography

Load Geist and Geist Mono (Google Fonts, the `geist` npm package, or self-hosted files). The fallbacks in `--font-sans` and `--font-mono` are acceptable when the fonts cannot load.

| Role | Face | Size | Weight | Other |
|---|---|---|---|---|
| Brand in top bar | mono | `--text-sm` | 700 | uppercase, `letter-spacing: 0.08em` |
| Page title (`h1`) | sans | `--text-lg` | 700 | `letter-spacing: -0.01em` |
| Panel title, micro label, table header | sans | `--text-xs` | 600 | uppercase, `0.05em`, `--label` |
| Body text | sans | `--text-md` | 400 | line-height 1.4 |
| Long-form text (docs, help, articles) | sans | `--text-md` or one step up | 400 | line-height 1.55, max width 40rem, `h2` and `h3` in sentence case at 700 |
| Meta line, cell text | sans | `--text-sm` | 400 | `--muted-foreground` for meta |
| Card title, row name | sans | `--text-md` | 700 (card), 600 (row) | one line, truncated |
| Machine value | mono | same as context | 400 to 600 | `tabular-nums` |
| Input value | mono | `--text-md` | 400 | Free-text fields for prose (a comment, a name) may use sans |
| Badge | sans | `--text-xs` | 700 | uppercase, `0.04em` |
| Button, chip | sans | `--text-sm` / `--text-xs` | 600 | uppercase, `0.04em` |
| Stat value | sans | `--text-xl` | 800 | `letter-spacing: -0.02em`, `tabular-nums` |
| Hero metric | sans | `--text-hero` | 800 | same |
| Log, code, JSON | mono | `--text-xs` | 400 | line-height 1.4 to 1.5 |

Rules:

1. Write source text in sentence case ("Save changes", "Members"). CSS applies `text-transform: uppercase` to labels, buttons, chips, badges, and nav. Type capitals in source only for acronyms. A screen reader then reads words, not letters.
2. Big display numbers (stat, hero) and numbers inside a sentence use the sans face. Every other machine value uses the mono face.
3. Every number that can change or that sits in a column uses `font-variant-numeric: tabular-nums`, so digits do not shift.
4. One line of text that can be long truncates with an ellipsis and carries the full text in `title`. Unless it is a link, it also expands with a click or Enter (section 7.20). Do not wrap IDs or names inside table cells.
5. Do not use italic, except for "no output yet" placeholders in a log and for a term that a sentence defines.

## 5. Layout and density

The page shell (5.2) and the sticky and layer rules (5.8) are fixed. Everything else in this section is a default: the reference app's way. Start from it. An app may choose another content layout or density when its users need it, and it still uses the fixed rules and the components.

### 5.1 Setting the density

The default is no override: the reference app's density. Override the adjustable tokens (section 2.2) in `ui-local.css` only for one of these reasons, and write the reason in a comment above the override:

- The app is touch-first (phones, tablets, kiosks).
- The app is mostly long reading (docs, help, articles).
- The users are occasional, non-technical users who fill in forms more than they scan data.

For example, a comfortable density for the third case:

```css
/* ui-local.css: comfortable density.
   Reason: occasional, non-technical users who mostly fill in forms. */
:root {
  --text-xs: 0.75rem;
  --text-sm: 0.875rem;
  --text-md: 1rem;
  --text-lg: clamp(1.15rem, 2.4vw, 1.4rem);
  --control-h: 2.25rem;
  --control-h-compact: 2rem;
  --control-h-sm: 1.75rem;
  --row-h: 2.5rem;
  --topbar-height: 3rem;
  --page-pad-x: clamp(0.75rem, 2vw, 1.5rem);
  --page-pad-y: 1rem;
}

/* Touch-first screens: 44px targets */
@media (pointer: coarse) {
  :root {
    --control-h: 2.75rem;
    --control-h-compact: 2.75rem;
    --control-h-sm: 2.75rem;
    --row-h: 2.75rem;
  }
}
```

Rules for any density:

1. Keep the order of the type scale. Labels stay smaller than body text, and body text stays smaller than titles.
2. Change all control sizes together, so a button and the input next to it stay the same height.
3. On a touch-first screen, every target is at least 44px, and no information depends on hover (a `title` is not enough; show the text or put it behind a tap).
4. Choose one density per app. Do not mix densities between pages.

### 5.2 Page shell (fixed)

Every app uses this frame. It is the strongest part of the family look:

1. A skip link, then a top bar with a hairline bottom border. It holds the brand (a 9px square mark plus the app name in mono caps), the site nav, and an aside on the right for global items (the age of live data, the user menu).
2. `main` with `--page-pad-y` / `--page-pad-x` padding.
3. A page header: the `h1` on the left, a muted aside on the right (counts, time range, last update), baseline-aligned.
4. If the section has sub-pages, a row of chips under the header (sub-nav). The current one is inverted.
5. A toolbar (filters, view switch, bulk actions) with a hairline under it, when the page has data to filter.
6. The content.

Site nav links are micro labels with an underline. Hover turns them `--link`. The current page is `--foreground` with no underline. An app with more than 6 sections keeps the top bar and adds a left side nav under it: the same micro-label links, one per line, in a 12rem to 16rem column with a hairline on its right. The top bar then holds only the brand, the 3 to 6 main areas, and the aside.

### 5.3 Two page types

- **Scrolling page** (lists, search results, reports, settings, docs): the body scrolls. The filter toolbar (`ui-toolbar--sticky`) sticks to the top of the window. The table header sticks to the top of its `ui-table-wrap`.
- **Fill-viewport page** (a dashboard or a detail view with several panes): use `ui-shell--fill`, then `ui-split` with one `ui-pane` per column. Each pane scrolls by itself. The split is `minmax(260px, 1fr) minmax(0, 2.5fr)`, and it becomes one scrolling column under 900px. A table inside a pane uses `ui-table-wrap ui-table-wrap--fill` so it takes the pane height.

### 5.4 Widths

- Tables, grids, and charts use the full width.
- Forms: max width 1040px. Fields flow in `repeat(auto-fit, minmax(190px, 1fr))`. A settings form with one column of fields: max width 40rem.
- Prose (a verdict, an explanation, a docs page): max width 34rem to 40rem.
- Dialogs: `min(720px, 100% - 1rem)`.

### 5.5 Grids

- Status cards: `repeat(auto-fill, minmax(clamp(18rem, 28vw, 26rem), 1fr))`, `grid-auto-rows: 1fr` so every card in a row has the same height.
- Compact tiles: `repeat(auto-fill, minmax(clamp(8rem, 28vw, 11rem), 1fr))`.
- Label and value pairs: `9rem 1fr`.
- Ranked bars: `10rem 1fr 3.5rem` (name, bar, number).

### 5.6 Spacing

The `--space-*` tokens are for page layout: the gaps between blocks, panels, and groups. Component internals in `components.css` use their own fixed values. Do not copy those values for layout.

| Gap | Default use |
|---|---|
| `--space-1` 0.15rem | Inside a label and its mark |
| `--space-2` 0.25rem | Inside a control group, between row actions |
| `--space-3` 0.35rem | Between buttons, between chips |
| `--space-4` 0.5rem | Between fields, cards, panels, toolbar items |
| `--space-5` 0.75rem | Between sections in one panel |
| `--space-6` 1rem | Between spec items, between major page blocks |
| `--space-7` 1.5rem | Between stat groups, between settings sections |

### 5.7 Responsive rules

- Page breakpoints (media queries on the window): 900px and 640px. Under 900px, split panes and two-column grids become one column, and a fill-viewport page becomes a scrolling page. Under 640px, field rows and filter rows stack.
- Container breakpoints (container queries on the component's own box): 700px for a list row that turns into a stacked block, 800px for a form and log pair that stacks.
- On a narrow screen, hide the table columns that repeat data visible elsewhere before you shrink text. Never go below `--text-xs`.
- No horizontal page scroll at 375px wide. Wide tables scroll inside their `ui-table-wrap`.

### 5.8 Sticky things and layers

This part is fixed. Only these elements are sticky:

| Element | How | z-index |
|---|---|---|
| Table header row | Automatic in `ui-table`, inside `ui-table-wrap` | 2 |
| Heatmap column headers and row headers | Automatic in `ui-heatmap` | 2 and 1 |
| Search or filter toolbar | `ui-toolbar ui-toolbar--sticky` | 3 |
| Bottom action bar of a long form | `ui-actionbar` | 3 |
| Dialog header | Automatic in `ui-dialog` | 2 |

Other layers: a hovered chip 1, a focused chip 2, the region loading overlay 5, an open menu 20. A dialog uses the browser top layer. Do not add other z-index values.

### 5.9 Page recipes

Start from the closest recipe. Each is a default, not a rule.

**List of live items** (jobs, deploys, orders being processed). Scrolling page.
1. Page header: title, then "19 jobs · updated 3s ago" in the aside.
2. Toolbar (`ui-toolbar--sticky`): inline search fields, the primary "Search" button, saved presets, a view switch (List / Cards), a status filter, and the bulk actions at the right end.
3. Stat row: counts per state, a divider, then totals.
4. Data region: a table with tinted rows (list view) or a status-card grid (card view). The region keeps the old data on screen during a query change and shows the scoped overlay.
5. Poll every 3 to 5 seconds.

**List of records** (members, invoices, products). Scrolling page.
1. Page header: title, count in the aside, the primary "+ Add member" button at the right of the header.
2. Toolbar: search, filters, bulk actions.
3. A sortable table with a status badge column (no row tint), selection checkboxes when there are bulk actions, pagination under it.
4. A click on a row opens the detail page. A click on a filterable value (a team, a plan) filters by it.

**Detail** (one job, one order, one host). Scrolling page, or fill-viewport when it has several live panes.
1. A header strip: back link, title (truncated), state badge, mono ID, and the actions at the right.
2. A `ui-kv` list or a spec list with the main facts.
3. The parts of the object (steps, line items, workers) in a table. Past steps are muted (`ui-past`), the current step has `aria-current="true"`, a failed step is a flag row (`ui-flag` with `data-status="failure"`).
4. A history or events panel, newest first. Error events are flag rows.
5. If the object is live, poll every 5 seconds and stop when it is final.

**Form** (create, edit, launch). Scrolling page.
1. Required fields first, then optional fields, then advanced fields in a disclosure that shows how many are set.
2. Labels above fields. Hints under fields.
3. A sticky action bar for a long form: the primary action first, Cancel next, a destructive action (Reset, Delete) at the end.
4. If the form starts work that produces output, put a log viewer to the right of the form at 900px and wider, and a results panel with one card per created item under it.

**Search and report** (a results browser, an audit log). Scrolling page.
1. Sub-nav chips for sibling views.
2. A filter builder: one row per filter (field, operator, value, remove ✕), then "+ Add filter", then "Apply". The whole query is in the URL.
3. A summary strip (stat row) for the current result.
4. A sortable table. Rows can group under a header row with counts and a small mix bar. A click on a value adds it as a filter.
5. A click on a row opens a dialog with a key-value list of the full record.
6. Pagination at the bottom: « ‹ page 2 of 14 › ».

**Dashboard** (health or usage over time). Scrolling page.
1. Toolbar: time range, bucket size, filters, "Apply", and the age of the data.
2. A panel with the hero metric, a stat row, and the verdict sentence.
3. Chart panels in a 2-column grid that becomes 1 column under 900px.
4. Ranked-bar panels for "worst by category".
5. Poll every 60 seconds or more.

**Settings** (account, workspace, preferences). Scrolling page.
1. A left side nav with one link per settings section, or one long page with an `h2` per section.
2. Each section is a panel: a micro-label title, a one-line description in `--muted-foreground`, the fields in one column (max width 40rem), and its own "Save" button at the bottom right of the panel. Disable "Save" until a field changes.
3. After a save, the button label is "Saved" for 2 seconds. A failed save shows an error notice at the top of that panel.
4. Destructive settings (delete the workspace, revoke all tokens) go in the last panel, with a hairline above it and the danger style. They always confirm, and a very destructive one asks the user to type the name of the object.

**Sign-in and account access**. Single panel.
1. One panel, max width 22rem, centered horizontally, about one third down the page.
2. The brand mark and app name above it. No illustration, no tagline.
3. The fields, one primary button ("Sign in"), and links in `ui-link` for "Forgot password" and other paths.
4. Errors appear as a notice inside the panel, above the fields. Do not say which of the two fields was wrong.

**Reading page** (docs, help, release notes). Scrolling page.
1. Left side nav for the page tree, the article in the middle (max width 40rem, long-form text role), and an optional "On this page" list on the right at 1200px and wider.
2. Code examples in `ui-pre` with a "Copy" ghost button in the top right corner.
3. Callouts are notices (`ui-notice` with `data-status="progress"` for a note, `"warning"` for a caution).
4. Headings have anchor links that show "#" on hover.

**Control room** (a page that a person operates during a live event). Scrolling page.
1. Page header: title, the "Live" connection badge in the aside, and a link to the output URLs.
2. The live controls strip (section 7.27), sticky at the top.
3. Two columns at 1280px and wider: editing panels on the left (fields that save as you type), the output preview on the right (section 7.29), sticky. Under 1280px the preview moves above the panels.
4. Lists inside the panels (teams, games, crew) use reorder buttons (section 7.28), "+ Add …" buttons, and a danger remove button per item that asks first.

**First run** (an app with no data yet). The page the user will use every day, empty.
1. Do not build a separate welcome screen. Show the normal page with an empty state in the data region.
2. The empty state says what this page shows and gives the one action that creates the first item: "No projects yet. Create a project to start." and "+ Create project".

## 6. Surfaces, borders, and depth

- A panel is a 1px `--border` box with 2px corners on `--surface`. Panels do not nest more than one level.
- Strong emphasis is a 1px `--border-strong` line: under a table header, around a dialog or menu, around an outline button.
- There is no elevation. A popover or dialog is separated by its strong border and, for a dialog, the backdrop.
- **The state rail** is the signature mark: a 3px left edge in the state fill. Use it for notices, the current step in a list, a flag row, a busy part of a live object, and a result card. It means "this item has this state".
- A dashed hairline means "empty" or "optional": empty states, an optional sub-section.
- The hatch pattern (135deg stripes of `--hatch-a` and `--hatch-b`, 3px each) means "no data" or "not run". The checkerboard (`ui-checker`, 8px squares of the same two tokens) means "transparent" and appears only behind a preview of output with a transparent background. These are the only two gradients allowed.
- A header band (card header, log toolbar, list header) is `--hover-surface` with a hairline under it.

## 7. Components

The CSS for every component is in appendix A. Class names use the `ui-` prefix. In a CSS Modules project, put the same rules in `ui.module.css`, drop the prefix, and camelCase the rest: `ui-button--primary` becomes `ui.buttonPrimary`, `ui-cell-num` becomes `ui.cellNum`. Attribute selectors such as `[data-status="failure"]` stay as they are.

State-bearing components read `--state` and `--state-text` from the nearest `data-status` attribute: `data-status="success|failure|progress|warning|inactive|skipped|accent|neutral|none"`. The attribute cascades to children. To stop a child from following its parent, give the child its own `data-status`; `none` removes the state. The attribute is `data-status`, not `data-state`, because Radix and shadcn/ui already write `data-state="open"` on their elements.

Section 7.30 lists every class in `components.css`.

### 7.1 Button

```html
<button class="ui-button ui-button--primary">Save changes</button>
<button class="ui-button">Retry</button>
<button class="ui-button ui-button--danger">Delete</button>
<button class="ui-button ui-button--quiet ui-button--small">Columns</button>
<button class="ui-button ui-button--ghost ui-button--small">Copy</button>
<button class="ui-button-link">Clear all</button>
```

| Kind | Look | Use for |
|---|---|---|
| default | Outline in `--border-strong`, fills with `--foreground` on hover | Most actions |
| primary | Filled `--foreground` | The one commit action of a region: Save, Search, Create, Apply. One per region |
| danger | Outline and text in failure colors, fills on hover | Destructive actions. Always confirmed (section 12.5) |
| quiet | Hairline outline, muted text | Secondary tools in a dense toolbar |
| ghost | No outline. Hover shows a gray background | Tertiary: Cancel, Copy, Save preset |
| compact | 25.6px tall by default | Buttons in a toolbar next to compact inputs |
| small | 24px tall by default | Row and card actions |
| link | Underlined `--link` text | An action inside a sentence |

Rules:

1. Labels are a verb or a verb and a noun, 1 to 3 words: "Save changes", "Invite member", "Cancel selected".
2. An action that adds a row or an item starts with "+ ": "+ Add filter", "+ Invite member".
3. While the action runs, disable the button and change the label to the present participle with an ellipsis character: "Saving…". There is no spinner.
4. A disabled button keeps its place and explains why in `title`: "No failed jobs in this view". A `title` is not reachable by keyboard or touch, so when the reason blocks a task (a form that cannot be sent), also show it as text (`ui-blockers`, section 7.7).
5. The danger button sits last in a group, or apart from the others with `margin-left: auto`.
6. An icon-only button (✕, ↻) has an `aria-label`.
7. A copy button is a ghost small button labeled "Copy". After a copy, the label is "Copied" for 2 seconds.

### 7.2 Chip (toggle)

A chip is a small uppercase toggle with a hairline border. Use it for on/off filters ("Failures only"), sub-nav links, and multi-select options.

```html
<button class="ui-chip" aria-pressed="true">Failures only</button>
<a class="ui-chip" href="/reports/usage" aria-current="page">Usage</a>
```

Pressed or current chips invert. A toggle chip uses `aria-pressed`. A nav chip uses `aria-current="page"`.

### 7.3 Segmented control

Use it to pick one of 2 to 4 views or modes: "List / Cards", "Daily / Weekly", "Jobs / Steps".

```html
<div class="ui-segmented" role="radiogroup" aria-label="View">
  <button class="ui-chip" role="radio" aria-checked="true" tabindex="0">List</button>
  <button class="ui-chip" role="radio" aria-checked="false" tabindex="-1">Cards</button>
</div>
```

- It is a radio group: one option is always checked. Only the checked option is in the tab order (roving `tabindex`). Arrow keys move the check and the focus.
- For more than 4 options, use a select.
- A chip with `aria-pressed` is an independent toggle, not a segmented option.

### 7.4 Badge

A badge shows a state word. It is uppercase, on a light tint of its state (`--badge-tint`), in its `-text` color.

```html
<span class="ui-badge" data-status="failure">Failed</span>
<span class="ui-badge" data-status="progress"><span class="ui-dot"></span>Running</span>
<span class="ui-badge ui-badge--data" data-status="accent">⧉ 4812</span>
```

- The data variant (`ui-badge--data`) holds a value, not a word: mono, no uppercase. Use it for a group ID, a version, a tag, a counter.
- A badge that links (a group badge that filters to its group) inverts on hover: its `-text` color becomes the fill, and the text becomes `--background`.
- A badge is never a button. If it toggles, it is a chip.
- On a tinted row or tile, a badge sits on `--surface` (section 3.3).

### 7.5 Stat row and hero metric

```html
<div class="ui-stats" role="group" aria-label="Summary">
  <div class="ui-stat"><span class="ui-stat-value">12</span><span class="ui-stat-label">Running</span></div>
  <div class="ui-stat" data-status="failure"><span class="ui-stat-value">6</span><span class="ui-stat-label">Failed</span></div>
  <span class="ui-stat-divider" aria-hidden="true"></span>
  <div class="ui-stat"><span class="ui-stat-value">2.68TB</span><span class="ui-stat-label">Storage</span></div>
</div>
```

- The stat row sits above the data it summarizes. A divider separates counts from totals.
- A page that answers one question (a health report) leads with one hero metric, then a **verdict**: one or two sentences that say what the number means and where to look. Example: "**397 of 760 jobs failed.** Most stopped at the install step (67, 16.9%). Worst day: 2026-09-19 at 0.0%."

### 7.6 Panel

```html
<section class="ui-panel" aria-labelledby="p1">
  <h2 class="ui-panel-title" id="p1">Healthy % per day <span class="ui-panel-title-aside">30 days</span></h2>
  ...
</section>
```

The panel title is a micro label, not a large heading. Put a short note (`ui-panel-title-aside`, sentence case) or controls that belong to the panel on the right side of the title row.

### 7.7 Toolbar and fields

```html
<div class="ui-toolbar" role="search">
  <label class="ui-field ui-field--inline">
    <span class="ui-field-label">Name</span>
    <input class="ui-input ui-input--compact" name="name" />
  </label>
  <button class="ui-button ui-button--primary ui-button--compact">Search</button>
  <span class="ui-toolbar-end ui-mono ui-muted">19 jobs</span>
</div>
```

- In forms, the label sits above the field. In toolbars and filter rows, the label sits left of the field (`ui-field--inline`) and the control is compact.
- Input values are mono. A field for prose (a comment, a description, a person's name) may add `font-family: var(--font-sans)` in `ui-local.css`.
- Placeholders show an example of the format only ("2026-10-14"), never an instruction that the user must keep.
- A required field has a `*` in `--failure-text` with `aria-hidden="true"`, plus `aria-required="true"` on the input.
- A hint sits under the field in `--text-xs`. A warning hint uses `--warning-text`. An error hint uses `--failure-text`, and the input gets `aria-invalid="true"` and `aria-describedby` pointing at the hint.
- Validate a field when it loses focus and again on submit, not on every key press.
- A form may save as the user types, with no Save button. Then its panel title aside shows "Saving…" while a write is in flight and "saved 2s ago" (`ui-age`) after it, and a failed write shows an error hint at the field and an error notice at the top of the panel. Never lose a change in silence.
- When a form cannot be submitted, list the blockers in a `ul.ui-blockers` under the primary button and point the button's `aria-describedby` at the list. Do not hide the button.
- Checkboxes and radio buttons are native inputs (`accent-color: var(--foreground)` is set in `components.css`), with the label to the right.
- Free-form query input (for example a SQL `where` clause) is a mono textarea with a one-line example under it.

### 7.8 Table

The table is the main component for data. Build it from plain HTML. Do not use a data-grid library unless the dataset needs virtualization; if you must, restyle it to match this section.

```html
<div class="ui-table-wrap">
  <table class="ui-table">
    <thead>
      <tr>
        <th aria-sort="descending"><button class="ui-sort">ID <span aria-hidden="true">▼</span></button></th>
        <th>Owner</th>
        <th class="ui-cell-num">Size</th>
        <th>Status</th>
      </tr>
    </thead>
    <tbody>
      <tr class="ui-tint" data-status="failure">
        <td class="ui-cell-mono"><a class="ui-id-link" href="/jobs/610781">610781</a></td>
        <td>ana</td>
        <td class="ui-cell-num ui-cell-mono">224GB</td>
        <td><span class="ui-badge" data-status="failure">Failed</span></td>
      </tr>
    </tbody>
  </table>
</div>
```

Rules:

1. A table always sits in `ui-table-wrap`. The wrap is the scroll container on both axes, so the header can stick inside it. Its height is capped by `--table-max-h` (default `100dvh - 10rem`). In a fill-viewport pane, add `ui-table-wrap--fill`.
2. Cells do not wrap. If one column holds prose (a description), give its cells the `ui-cell-wrap` class. Truncated text in a cell is capped at `--cell-max` (default 20rem); set it on the table or the cell.
3. Headers are micro labels with a strong bottom border, sticky at the top of the scroll container.
4. ID, time, size, amount, and version cells use `ui-cell-mono`. Number cells and their header use `ui-cell-num` (right-aligned, tabular). The main name in a row uses `ui-row-name` (weight 600).
5. A sortable header is a `ui-sort` button. The sorted header has `aria-sort` and shows ▲ or ▼. Missing values sort last in both directions.
6. Row hover is `--hover-surface`. Tint whole rows by state (`ui-tint`, 45%) on a page whose main task is to find items by state (a monitor of live work). On other pages, put a badge in a status column and leave the row on the surface.
7. A row that needs attention without a full tint (a failed step, an error event) is a flag row: `ui-flag` with `data-status`. It gets a 14% tint, a rail, and `-text` color.
8. The current item in a step list gets `aria-current="true"`: a rail and weight 600. Past items get the `ui-past` class and are muted.
9. A group header row (`ui-group-row`) is `--hover-surface` with a strong top border and the group's counts in mono.
10. A missing value is "—".
11. Rows that can be selected for a bulk action have a checkbox in the first column, with an `aria-label` that names the row ("Select job 607497"). The selected `tr` gets `data-selected` for the gray highlight. (`aria-selected` is valid only in an ARIA grid, so the checkbox carries the state.) A header checkbox selects all rows in view.
12. A value that names a filter (owner, group, category) is a link that applies that filter. Use real links so middle-click opens a new tab.
13. A table with more than 6 columns lets the user hide and resize columns. Use `ui-table--fixed` with widths on `<col>` elements, a `ui-resize-handle` inside each `th.ui-th-resizable`, and a "Columns" menu with a checkbox and a width input per column. Store widths and hidden columns in `localStorage`.
14. On a narrow screen, a table may become a list of cards (one card per row) through a container query. Keep the same order of facts.

### 7.9 Progress bar

```html
<div class="ui-progress" data-status="progress" style="--value: 68%" role="progressbar" aria-valuenow="68" aria-valuemin="0" aria-valuemax="100" aria-label="Progress: 68%">
  <div class="ui-progress-fill"></div>
</div>

<div class="ui-progress ui-progress--labeled" data-status="failure" style="--value: 25%" role="progressbar" aria-valuenow="25" aria-valuemin="0" aria-valuemax="100" aria-label="Progress: 13 of 52 steps">
  <div class="ui-progress-fill"></div>
  <span class="ui-progress-label">13/52</span>
  <span class="ui-progress-label ui-progress-label--on-fill" aria-hidden="true">13/52</span>
</div>
```

- Set the value once, as the `--value` custom property on the bar (`style={{ "--value": "25%" }}` in React). The fill width and the label clip both read it.
- Set `data-status` on the bar, not on the fill.
- The plain bar is 8px tall and sits under a line that shows the current step (left, truncated, muted) and "n/m" (right, mono).
- The labeled bar is 18px tall with the mono label centered on it. Use it in table cells and tiles. The label is short: "n/m" or "68%", at most 7 characters.
- The labeled bar has the label twice. The first copy is `--foreground` and shows over the empty track. The second copy (`ui-progress-label--on-fill`, `aria-hidden="true"`) is `--on-fill` and is clipped to the filled part. The fill stays solid, and the text passes 4.5:1 on both parts in both modes. Do not use `--accent` as a progress state, because its light fill is dark.
- The fill color is the state of the item, not a fixed blue. A failed item shows a red bar stopped at the step where it failed.
- The width does not animate.
- A usage meter (storage used, seats used) is the same bar. Use `progress` below 80%, `warning` from 80%, `failure` at 100%.

### 7.10 Status card

The card shows one object with a state (a job, an order, a deploy) in a grid.

```html
<ul class="ui-cards" role="list">
  <li class="ui-card" aria-label="Job nightly-export-eu, Failed">
    <div class="ui-card-header">
      <span class="ui-badge" data-status="failure">Failed</span>
      <span class="ui-card-id">#610781 <a class="ui-badge ui-badge--data" data-status="accent" href="?group=4812">⧉ 4812</a></span>
    </div>
    <div class="ui-card-body">
      <a class="ui-card-title ui-truncate" href="/jobs/610781">nightly-export-eu</a>
      <span class="ui-card-meta">ana <span class="ui-sep">·</span> expires in 20h 31m</span>
      <div class="ui-card-progress">
        <div class="ui-card-progress-head">
          <span class="ui-truncate ui-muted">Upload files</span>
          <span class="ui-mono">50/104</span>
        </div>
        <div class="ui-progress" data-status="failure" style="--value: 48%" role="progressbar" aria-valuenow="48" aria-valuemin="0" aria-valuemax="100" aria-label="Progress: 48%">
          <div class="ui-progress-fill"></div>
        </div>
      </div>
      <dl class="ui-spec">
        <div><dt>Size</dt><dd>224GB</dd></div>
        <div><dt>Workers</dt><dd>6</dd></div>
      </dl>
    </div>
    <div class="ui-card-footer" role="group" aria-label="Job actions">
      <button class="ui-button ui-button--small">Retry</button>
      <button class="ui-button ui-button--small">Extend</button>
      <button class="ui-button ui-button--small ui-button--danger">Cancel</button>
    </div>
  </li>
</ul>
```

Anatomy, top to bottom: header band (badge left, mono ID and group badge right), title (one line), meta line (owner, expiry, separated by " · "), progress block, spec list (micro label over mono value, hairline above), footer actions (right-aligned, small, hairline above). The card itself is not tinted. The badge and the bar carry the state. A card for an object without progress drops the progress block.

A **compact tile** (`ui-tile`) is the dense version for a grid of many objects: name, ID, step, and a labeled bar, with the whole tile tinted by state (`ui-tint`).

### 7.11 Spec list and key-value list

- `ui-spec` is a row of label-over-value items. Use it inside cards, 2 to 5 items.
- `ui-kv` is a two-column list (`9rem 1fr`) with hairlines between rows. Use it on a detail page, in a detail dialog, or in a side pane. Values are mono and break anywhere.

### 7.12 Notice

```html
<div class="ui-notice" data-status="failure" role="alert">
  Save failed (HTTP 500). The server did not answer.
  <button class="ui-button ui-button--ghost ui-button--small ui-notice-end" aria-label="Dismiss">✕</button>
</div>
```

- A notice has a state rail, a 14% tint, and `-text` color.
- Errors use `role="alert"` and a dismiss button. Info uses `role="status"`.
- Put the notice at the top of the region it is about, not in a global corner. There are no toasts and no `alert()`.
- A notice for the whole app (planned maintenance, a read-only mode) sits under the top bar, full width, on every page, until the condition ends.

### 7.13 Empty state

A dashed box with one muted sentence that ends with a period, then what to do. If one action clears the empty state ("Clear filters", "+ Create project"), add that one button.

> No invoices match these filters. Clear a filter or choose a longer period.

### 7.14 Loading

| Situation | Show |
|---|---|
| First load of a region | Static text in the region: "Loading invoices…", `role="status"` |
| Background refresh | Nothing. Update the "updated Ns ago" readout if the page shows one |
| The user changed the query | A 70% `--background` overlay on the data region only, with "Loading invoices…". The old data stays under it |
| A value inside a cell | "…" |

Static placeholder bars in `--hover-surface` are allowed. They do not shimmer or pulse.

### 7.15 Disclosure and menu

- A collapsible section is `<details class="ui-disclosure">` with a micro-label `<summary>` and a ▸ / ▾ glyph. Use it for advanced options, raw JSON, request payloads.
- A menu (column picker, more actions, the user menu) is a `<details class="ui-menu">` with a `ui-menu-panel`: absolutely placed, `--background`, a strong border, 2px corners, no shadow. `<details>` does not close by itself, so add this once per page:

```js
document.addEventListener("click", (event) => {
  for (const menu of document.querySelectorAll("details.ui-menu[open]")) {
    if (!menu.contains(event.target)) menu.open = false
  }
})
document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape") return
  for (const menu of document.querySelectorAll("details.ui-menu[open]")) {
    menu.open = false
    menu.querySelector("summary").focus()
  }
})
```

- A disclosure that is a button (not `<details>`) uses `aria-expanded` and can show a count: "Advanced options (3 set)".

### 7.16 Dialog

Use the native `<dialog>` element with `showModal()`. Use a dialog only for the detail of one record, for a confirmation, or for a short form of at most 4 fields. A longer form is a page.

```html
<dialog class="ui-dialog" aria-labelledby="d1">
  <div class="ui-dialog-header">
    <h2 class="ui-dialog-title ui-mono" id="d1">INV-2026-0412</h2>
    <button class="ui-button ui-button--ghost ui-button--small" aria-label="Close">✕</button>
  </div>
  <div class="ui-dialog-body"><dl class="ui-kv">...</dl></div>
</dialog>
```

- The dialog sits near the top of the window, not centered vertically.
- Esc closes it. Focus goes back to the control that opened it.
- Add `ui-mono` to the title when it is an identifier.

A confirmation uses the same dialog, with the question as the title, the consequence in the body, and two buttons. Cancel has `autofocus`, so Enter does not destroy anything by accident:

```html
<dialog class="ui-dialog" aria-labelledby="c1">
  <div class="ui-dialog-header"><h2 class="ui-dialog-title" id="c1">Delete 3 invoices?</h2></div>
  <div class="ui-dialog-body"><p>Deleted invoices cannot be restored.</p></div>
  <div class="ui-dialog-footer">
    <button class="ui-button" autofocus>Cancel</button>
    <button class="ui-button ui-button--danger">Delete 3 invoices</button>
  </div>
</dialog>
```

### 7.17 Log and console viewer

- A header band (`ui-log-toolbar`) holds mono meta (source, line count) and tools.
- The body is mono `--text-xs`, line height 1.4, `pre-wrap`, scrolls by itself.
- Highlight a matching line with a 15% `--progress` tint across the full width. Dim lines outside a filter to 25% opacity. Show "No output yet." in italic `--label` when empty.
- If there are several logs, put a `ui-tabs` row above the body, one tab per log, with a `ui-tab-count` per tab (section 7.21).

### 7.18 Sticky action bar

A long form ends with a bar that sticks to the bottom of its scroll container: `--background`, a hairline on top, the primary action first, the destructive action last (`ui-actionbar-end`).

### 7.19 Code and JSON block

Mono `--text-xs` on `--hover-surface` with a hairline border, max height 24rem, scrolls. Raw JSON goes behind a disclosure, not on the page by default. A code example on a reading page has a "Copy" button.

### 7.20 Truncated text

Long names and descriptions show one line (or a clamp of 2 or 3 lines) with an ellipsis. When the text is clipped:

1. Put the full text in `title`.
2. Make it focusable (`tabindex="0"`, `role="button"`, `aria-expanded`).
3. Click, Enter, or Space expands it in place. The row grows. Nothing moves elsewhere.

Measure clipping with a `ResizeObserver`; do not guess from the character count.

A truncated link stays a link: it gets the `title` but does not expand. Put the full text somewhere else on the target page.

### 7.21 Tabs

Tabs switch between sibling panels inside one region (several logs, the sections of a detail page). Sub-nav chips switch pages. A segmented control switches the view of the same data.

```html
<div class="ui-tabs" role="tablist" aria-label="Logs">
  <button class="ui-tab" role="tab" aria-selected="true" aria-controls="log-1" id="tab-1">Build <span class="ui-tab-count">214</span></button>
  <button class="ui-tab" role="tab" aria-selected="false" aria-controls="log-2" id="tab-2" tabindex="-1">Tests <span class="ui-tab-count">14</span></button>
</div>
<div role="tabpanel" id="log-1" aria-labelledby="tab-1">...</div>
```

Arrow keys move between tabs (roving `tabindex`). Put the selected tab in the URL.

### 7.22 Pagination

```html
<nav class="ui-pagination" aria-label="Pages">
  <button class="ui-button ui-button--quiet ui-button--small" aria-label="First page">«</button>
  <button class="ui-button ui-button--quiet ui-button--small" aria-label="Previous page">‹</button>
  <span class="ui-pagination-status">page 2 of 14</span>
  <button class="ui-button ui-button--quiet ui-button--small" aria-label="Next page">›</button>
  <button class="ui-button ui-button--quiet ui-button--small" aria-label="Last page">»</button>
</nav>
```

Pagination sits under the table, right-aligned. Disable the buttons that do not apply. The page number is in the URL.

### 7.23 Filter builder

One row per filter: field (select), operator (select), value (compact input), and a remove button (✕). Under the rows: "+ Add filter" (ghost) and "Apply" (primary).

```html
<div class="ui-filter-rows">
  <div class="ui-filter-row">
    <select class="ui-select ui-input--compact" aria-label="Field"><option>region</option></select>
    <select class="ui-select ui-input--compact" aria-label="Operator"><option>=</option></select>
    <input class="ui-input ui-input--compact" aria-label="Value" value="eu-west">
    <button class="ui-button ui-button--ghost ui-button--small" aria-label="Remove filter">✕</button>
  </div>
</div>
```

### 7.24 Time range

A time range is a segmented control (section 7.3) for the common windows ("24h", "7d", "30d"), and a "Custom" option that shows two `<input type="datetime-local" class="ui-input ui-input--compact">` fields. Show the resolved range in the page header aside: "2026-09-15 to 2026-10-14".

### 7.25 Full-page states

When a whole page cannot show its content (not found, server unreachable, no access), replace the main content:

```html
<div class="ui-page-state" data-status="failure" role="alert">
  <h1 class="ui-page-state-title">Invoice INV-2026-0412 not found</h1>
  <p>It may have been deleted. Search all invoices to find it.</p>
  <a class="ui-button" href="/invoices">All invoices</a>
</div>
```

Keep the top bar, so the user can go elsewhere. The title uses the failure role for all three cases. The text says which case it is and what to do next.

### 7.26 Split panes

`ui-split` holds 2 `ui-pane` columns on a fill-viewport page (section 5.3). Each pane is a flex column, so a `ui-table-wrap--fill` or a `ui-log` inside it takes the remaining height.

### 7.27 Live controls

A page that a person operates during a live event (a broadcast, a match, an incident) has a strip of live controls: the actions the operator hits with no time to read.

```html
<div class="ui-toolbar ui-toolbar--sticky" role="group" aria-label="Live controls">
  <div class="ui-stepper" role="group" aria-label="Score, Harbour Kings">
    <button class="ui-button" aria-label="Lower score, Harbour Kings">−</button>
    <span class="ui-stepper-value" aria-live="polite">2</span>
    <button class="ui-button" aria-label="Raise score, Harbour Kings">+</button>
  </div>
  <button class="ui-button">⇄ Swap sides</button>
  <button class="ui-button">‹ Previous game</button>
  <button class="ui-button">Next game ›</button>
  <button class="ui-button ui-button--danger ui-toolbar-end">Reset scores</button>
</div>
```

- The strip is sticky at the top of the page and its buttons never move: the order is fixed, and no button appears or disappears while the event runs. A button that does not apply is disabled.
- Live controls use the default control height (`--control-h`), also in a toolbar, and at least 44px on a touch screen.
- A change applies at once. A destructive or hard-to-undo control (reset, end the show) asks first (section 12.5).
- A counter is a stepper: − and + buttons around the value in large mono. The value is a live region so a screen reader hears the change.
- The page shows that it is connected, and so on air, with a static dot and the word "Live" (`ui-badge` with `data-status="progress"` and a `ui-dot`). It never pulses.

### 7.28 Reordering a list

Each item that can move has two ghost small buttons, ↑ and ↓, with labels that name the item ("Move game 3 up"). The first item's ↑ and the last item's ↓ are disabled. After a move, the focus stays on the button that was pressed, on the item's new place. Drag and drop is allowed only in addition to the buttons.

### 7.29 Output preview

A page that edits output (section 0.1) shows a live preview of it.

```html
<section class="ui-panel" aria-labelledby="pv1">
  <h2 class="ui-panel-title" id="pv1">Preview <span class="ui-panel-title-aside">scorebug · 1920×1080</span></h2>
  <div class="ui-preview ui-checker" style="--preview-ratio: 16 / 9">
    <iframe src="/overlays/summer-cup/scorebug" title="Scorebug preview"></iframe>
  </div>
  <div class="ui-field-row" style="margin-top: var(--space-3)">
    <code class="ui-pre ui-truncate">https://example.com/overlays/summer-cup/scorebug</code>
    <button class="ui-button ui-button--ghost ui-button--small">Copy</button>
  </div>
</section>
```

- The frame has the output's aspect ratio (`--preview-ratio`), a hairline border, and the checkerboard behind it when the output is transparent.
- `components.css` sets `color-scheme: normal` on the preview iframe. Keep it: a browser paints an iframe opaque when the iframe's color scheme differs from the page inside it, so without it a transparent output turns white in dark mode.
- The output inside the frame keeps its own design. Do not restyle it to match the app.
- Put a selector for the variants (scenes, pages, sizes) above the frame as a segmented control, or as a select when there are more than 4.
- On a wide screen the preview panel is sticky at the top of its column, so it stays in view while the user edits the fields beside it.

### 7.30 Class index

| Group | Classes |
|---|---|
| Page shell | `ui-skip-link`, `ui-shell`, `ui-shell--fill`, `ui-topbar`, `ui-brand`, `ui-brand-mark`, `ui-sitenav`, `ui-topbar-aside`, `ui-main`, `ui-page-header`, `ui-title`, `ui-title-aside`, `ui-subnav`, `ui-toolbar`, `ui-toolbar--sticky`, `ui-toolbar-end`, `ui-split`, `ui-pane` |
| Text | `ui-label`, `ui-mono`, `ui-num`, `ui-muted`, `ui-sep`, `ui-truncate`, `ui-clamp` (lines in `--clamp-lines`), `ui-sr-only`, `ui-age` (`data-stale` for old data), `ui-expiring` |
| Links | `ui-link`, `ui-id-link`, `ui-quiet-link`, `ui-alt-target` (with `data-alt-held` on `<html>`) |
| State | `data-status`, `data-outcome`, `ui-tint`, `ui-rail` |
| Panels | `ui-panel`, `ui-panel--strong` (a selected or focused panel only), `ui-panel-title`, `ui-panel-title-aside` |
| Buttons | `ui-button` with `--primary`, `--danger`, `--quiet`, `--ghost`, `--compact`, `--small`; `ui-button-link`, `ui-button-group` |
| Toggles | `ui-chip`, `ui-segmented`, `ui-tabs`, `ui-tab`, `ui-tab-count` |
| Status | `ui-badge`, `ui-badge--data`, `ui-dot` |
| Numbers | `ui-stats`, `ui-stat`, `ui-stat-value`, `ui-stat-label`, `ui-stat-divider`, `ui-hero`, `ui-hero-value`, `ui-verdict` |
| Forms | `ui-field`, `ui-field--inline`, `ui-field-row`, `ui-field-label`, `ui-required`, `ui-input`, `ui-input--compact`, `ui-select`, `ui-textarea`, `ui-hint`, `ui-hint--warning`, `ui-hint--error`, `ui-blockers`, `ui-filter-rows`, `ui-filter-row` |
| Feedback | `ui-notice`, `ui-notice-end`, `ui-empty`, `ui-loading`, `ui-region`, `ui-region-overlay`, `ui-placeholder-bar`, `ui-page-state`, `ui-page-state-title` |
| Tables | `ui-table-wrap`, `ui-table-wrap--fill`, `ui-table`, `ui-table--fixed`, `ui-cell-num`, `ui-cell-mono`, `ui-cell-wrap`, `ui-row-name`, `ui-sort`, `ui-th-resizable`, `ui-resize-handle`, `ui-past`, `ui-flag`, `ui-group-row`, `ui-pagination`, `ui-pagination-status` |
| Progress | `ui-progress`, `ui-progress--labeled`, `ui-progress-fill`, `ui-progress-label`, `ui-progress-label--on-fill` (value in `--value`) |
| Cards | `ui-cards`, `ui-card`, `ui-card-header`, `ui-card-id`, `ui-card-body`, `ui-card-title`, `ui-card-meta`, `ui-card-progress`, `ui-card-progress-head`, `ui-card-footer`, `ui-tiles`, `ui-tile`, `ui-spec`, `ui-kv` |
| Overlays | `ui-disclosure`, `ui-menu`, `ui-menu-panel`, `ui-dialog`, `ui-dialog-header`, `ui-dialog-title`, `ui-dialog-body`, `ui-dialog-footer` |
| Logs and code | `ui-log`, `ui-log-toolbar`, `ui-log-meta`, `ui-log-body`, `ui-log-line`, `ui-log-line--highlight`, `ui-log-line--dim`, `ui-log-empty`, `ui-pre`, `ui-actionbar`, `ui-actionbar-end` |
| Live and output | `ui-stepper`, `ui-stepper-value`, `ui-preview` (ratio in `--preview-ratio`), `ui-checker`, `ui-color-swatch` (color in `--swatch`) |
| Charts | `ui-chart-wrap`, `ui-chart`, `ui-chart-grid`, `ui-chart-guide`, `ui-chart-line`, `ui-chart-area`, `ui-chart-dot`, `ui-chart-dot--empty`, `ui-chart-bar`, `ui-tooltip`, `ui-tooltip-row`, `ui-legend`, `ui-legend-item`, `ui-swatch`, `ui-swatch--line`, `ui-hatch`, `ui-heatmap`, `ui-heat-cell`, `ui-rank`, `ui-rank-track` |

## 8. Motion

1. Color, background color, border color, and opacity may change over `--duration-color` (120ms, `ease`). That is the only transition.
2. Nothing moves, grows, slides, spins, pulses, or fades in on load. No `transform` transitions, no width or height transitions, no keyframe animations. This includes page transitions and route changes.
3. A progress bar jumps to its new width.
4. Include the `prefers-reduced-motion` block from appendix A anyway. It removes the color fades too.

Static transforms are allowed when they are not motion, for example `writing-mode: vertical-rl` with `rotate(180deg)` for vertical column headers.

## 9. Glyphs and icons

There is no icon library. Use these Unicode glyphs, and use each one only for the meanings in its row.

| Glyph | Meaning |
|---|---|
| ▲ ▼ | Sort direction. Also a change up or down next to a delta |
| ↑ ↓ | Move an item up or down in a list |
| ⇄ | Swap two sides or two items |
| − + | Lower or raise a counter (use the minus sign U+2212, not a hyphen) |
| ▸ ▾ | Collapsed, expanded |
| ✕ | Close, dismiss, remove. Also "failed" in a pass/fail mark |
| ✓ | Passed, done, saved |
| ⤼ | Skipped |
| ↗ | Opens another site or a new tab |
| ↻ | Refresh |
| ✎ | Edit |
| ⧉ | A group (batch, project, parent) in a data badge |
| « ‹ › » | First, previous, next, last page |
| ⚠ | Warning inside a confirmation text |
| · | Separator between items in a line |
| — | Missing value |
| … | In progress, or text that continues |
| # | Anchor link next to a heading on a reading page |

Rules:

1. A glyph inherits the text size and color.
2. A glyph that is decoration next to a word has `aria-hidden="true"`. A glyph that is the only content of a button needs `aria-label` on the button.
3. If no glyph fits, draw an inline SVG: 10 to 12px, `stroke="currentColor"`, stroke width 1.3, no fill, `aria-hidden="true"`, `focusable="false"`.
4. A product logo is the only image in the chrome. It sits in the top bar at the height of the brand text, in `--foreground` (one color).

## 10. Words

### 10.1 Voice

Short, literal, and specific. Write what happened and what to do next. No exclamation marks, no "Oops", no "Successfully", no "Please", no jokes. Address the user as "you" only when you must; most labels need no pronoun.

### 10.2 Patterns

| Situation | Pattern | Example |
|---|---|---|
| Button | Verb, or verb and noun | "Save changes", "Retry" |
| Add button | "+ " and verb and noun | "+ Invite member" |
| In-flight button | Participle and "…" | "Saving…" |
| Done button state | Past tense, 2 seconds | "Saved" |
| Loading | "Loading" and noun and "…" | "Loading invoices…" |
| Empty | Sentence, period, then the fix | "No members yet. Invite the first member." |
| Error | What failed, the cause, then a way out | "Save failed (HTTP 500)." and a Retry button |
| Server down | Name the part that is down | "Billing service unreachable." |
| Not found | Name the object | "Invoice INV-2026-0412 not found." and "All invoices" |
| Confirm | Verb, count, noun, question mark. Then the consequence | "Delete 3 invoices? Deleted invoices cannot be restored." |
| Copy feedback | One word, 2 seconds | "Copied" |
| Disabled reason (`title`) | Why, as a statement | "No failed jobs in this view" |
| Definition (`title`) | How the number is computed | "Paid invoices out of all sent invoices. Drafts are excluded." |

### 10.3 Consistency rules

1. One word per meaning across the whole app. If one page says "Failed", no page says "Error", "ERR", or "Errored" for the same state.
2. Use the ellipsis character "…" (U+2026), never three periods.
3. Separate items in a line with " · " (space, middle dot, space). Do not use "|" or "•".
4. Write IDs as "#610781", or in the format the domain uses ("INV-2026-0412"). Prefix the system or region when there are two: "EU #610781".
5. Abbreviations from the domain are fine ("GB", "SKU", "+1d"). Explain each in a `title` the first time it appears on a page.

## 11. Data formatting

Format dates and numbers in one module, through `Intl.DateTimeFormat` and `Intl.NumberFormat`, so every page agrees.

| Value | Format | Notes |
|---|---|---|
| Last update | "updated 3s ago" | Ticks every second. Turns `--warning-text` when older than 2 times the refresh interval. `aria-live="off"` |
| Future time | "in 2d 3h", "in 3h 12m", "in 5m", "expired" | `title` holds the full local time. Less than 1 hour: `ui-expiring` (weight 600, `--warning-text`; on a tint, `--foreground`) |
| Past time in a list of events | "09:02:15" today, "10-13 09:02:15" this year, "2025-12-30 09:02:15" before | Absolute, newest first. Relative time is only for the "updated" readout |
| Absolute time | "2026-10-14 09:02:15" | Local, 24-hour, zero-padded. An app for a general audience may use the locale's medium date ("14 Oct 2026, 09:02") instead. Pick one form per app |
| Date on a chart axis | "10-14" | Drop the year when the range is inside one year |
| Duration | "01:23:45" | `HH:MM:SS`. A running item counts up against now |
| Size | "72GB", "2.68TB" | No space. TB with 2 decimals at 1024GB and above |
| Money | "$1,240.00", "€1.240,00" | The locale's format, 2 decimals, mono and right-aligned in tables, the currency code in the column header when a table mixes currencies |
| Progress | "68%", "50/104" | Integer percent. Steps as done/total in mono |
| Rate | "97.6%" | One decimal. Say in `title` what is excluded |
| Delta | "▲ 2.5", "▼ 1.0" | Color by good or bad, not by up or down |
| Count | "1 job", "3 jobs", "12,480 tests" | Real plurals, never "job(s)". Group thousands in the locale's way from 10,000 up. Never group digits in IDs |
| Missing | "—" | |
| ID | "#610781" | Mono |
| Version | "2026.3.0.149", short form "149" | Mono. Use the short form only where the long form is visible nearby |

## 12. Interaction

### 12.1 Live and changing data

1. Refresh a live view on an interval: every 3 to 5 seconds for running work, every 60 seconds or more for aggregates. A page without live work does not refresh by itself; it has a "Refresh" button if its data can change.
2. Stop refreshing an object when it reaches a final state.
3. Keep the previous data on screen while new data loads (SWR `keepPreviousData` or the same idea). Never unmount the page to show a loader.
4. A page that refreshes shows the age of its data ("updated 3s ago") in the page header or the top bar.
5. When the server pushes changes (WebSocket, Server-Sent Events, Phoenix LiveView), do not poll and do not show an age. Show the connection instead: "Live" with a static dot while connected. While disconnected, show an app-wide warning notice ("Connection lost. Reconnecting…") under the top bar, and disable the controls that need the server.

### 12.2 State in the URL

1. Filters, sort, page, tab, and the selected record go in the query string. Update it with `replace` for typing and `push` for deliberate changes. The Back button must work.
2. Personal preferences (view mode, column widths, hidden columns, saved presets) go in `localStorage`, or in the user's account when they must follow the user to other devices. Prefix the keys with the app name. Listen for the `storage` event so two tabs agree.
3. Saved searches ("presets") are named copies of the query. The picker shows the preset that matches the current query. "Save" and "Delete" appear only when they apply.

### 12.3 Navigation

1. In-app links are real links with client-side navigation. A filter link never reloads the page.
2. Optional: hold Alt to show an alternate destination (for example the same record in another system). While Alt is down, set `data-alt-held` on `<html>`; the links with `ui-alt-target` then show a dashed underline in `--link`. Alt+click opens the alternate page in a new tab.

### 12.4 Keyboard

| Key | Action |
|---|---|
| `/` | Focus the main search field, unless the focus is already in a field |
| `Esc` | Close the dialog, cancel the edit, close the menu |
| `Enter` | Commit an edit or an inline name. On a focusable row or on truncated text, activate it |
| `Space` | Activate a focusable row or expand truncated text |
| Arrow keys | Move inside a radio group (segmented control, mode picker) and a tab list |

### 12.5 Destructive and bulk actions

1. Every destructive action asks for confirmation, for one item and for many. The question names the verb, the count, and the noun: "Delete 3 invoices?". If the action cannot be undone, the text says so.
2. Ask with the confirmation dialog in section 7.16: the confirm button repeats the verb and count ("Delete 3 invoices") in the danger style, and Cancel has the focus. Use `window.confirm()` only in a prototype.
3. An action that starts many tasks at once, or that costs money or shared resources, first shows a dry run (the list of what it will do), then the confirmation.
4. An action that destroys a whole account, workspace, or project asks the user to type its name before the danger button turns on.
5. Bulk actions sit in a labeled group (`<nav aria-label="Bulk actions">` or `role="group"`) at the right end of the toolbar. Each one is disabled with a reason when nothing matches.
6. A reversible action may update the screen at once (optimistic update). If the request fails, undo the change and show an error notice in place.
7. Warn before the user leaves a page with changes that are not saved (`beforeunload`).

### 12.6 Feedback

Feedback appears next to the thing that changed: a notice at the top of the region, a label change on the button, a new row in the table. Nothing pops up in a corner.

## 13. Accessibility

1. The first focusable element is a skip link to `#main`. The page has `header`, `nav aria-label="Site"`, and `main id="main"`.
2. The current nav item has `aria-current="page"`.
3. Every focusable element shows a 3px `--focus` outline with a 2px offset on `:focus-visible`. Inputs use a 2px outline with a 1px offset. Never remove an outline without a replacement.
4. All text meets 4.5:1. The tokens meet it on `--background`, on a header band, on a badge tint, and on a 45% row tint when you follow section 3.3. Thin meaningful marks meet 3:1 by using the `-text` tier. Prove it with the contrast audit in appendix B, in light and in dark mode, at the density the app uses.
5. Color is never the only signal. A state has a word (badge), a letter (heatmap cell), or a glyph (✓ ✕ ⤼).
6. Loading and result counts are `role="status"` with `aria-live="polite"`. Errors are `role="alert"`. A ticking age readout is `aria-live="off"`.
7. A list of cards is `role="list"` and `role="listitem"`, and each item has an `aria-label` that includes its state: "Job nightly-export-eu, Failed".
8. A progress bar has `role="progressbar"` with `aria-valuenow`, `aria-valuemin`, `aria-valuemax`, and an `aria-label` in words.
9. A chart is `role="img"` with an `aria-label` that states the range and the main finding. The same numbers are available as text (the verdict, a table, or tooltips).
10. Sortable headers have `aria-sort`. Clickable rows are links or have `role="button"`, `tabindex="0"`, and Enter and Space handlers.
11. Click targets are at least 24 by 24 px (44 by 44 px on touch-first screens, section 5.1). Buttons, chips, tabs, nav links, sort headers, and disclosure summaries get this size from the tokens. Links and badges inside a sentence or a table cell use the WCAG 2.5.8 spacing exception: keep at least 24px between the centers of two targets.
12. Form fields have a real `<label>`. Required, invalid, and described fields use `aria-required`, `aria-invalid`, and `aria-describedby`. After a failed submit, move the focus to the first invalid field.
13. A dialog traps focus (the native `<dialog>` does this), closes on Esc, and returns focus to its opener.
14. Text can grow to 200% (browser zoom) without loss of content. Do not set heights in px on boxes that hold text.

## 14. Charts

You may draw charts with hand-written SVG or with a library. Either way, the result follows these rules.

1. A chart sits in a panel with a micro-label title that says what it shows and the unit: "Healthy % per day", "Revenue per week (USD)".
2. Above the chart, the page states the conclusion in words (the hero metric and the verdict, section 7.5). The chart supports the sentence.
3. Draw the chart at its real pixel width. Measure the container (a `ResizeObserver`) and set the SVG `viewBox` width to that number. Do not let a fixed `viewBox` scale the chart, because the axis text then shrinks or grows with it.
4. Horizontal gridlines only, at round values (0, 25, 50, 75, 100), 1px `--border`. No vertical gridlines, no frame around the plot, no axis lines.
5. Axis text: `--text-2xs`, mono, `--label`, tabular figures. Thin the labels so that they are at least 62px apart.
6. A line is 2px in the `-text` tier, with round joins. The area under it is the same color at 12% opacity. Points are circles with a 3px radius.
7. A missing bucket breaks the line. Mark it with a hollow dot on the baseline. Do not draw it as zero.
8. Bars are at most 24px wide. Stacked segments have a 2px gap. The stack order from the axis up is failure, success, inactive, skipped, so the worst outcome sits next to the axis. The legend uses the same order.
9. A chart of amounts without a state (revenue, sign-ups) uses `--foreground` for its single series (`data-status="none"` on the series group gives the foreground fallback). A second series uses `--label`. More than 2 series without states need a page palette (section 3.7) or small multiples.
10. Hover: a full-height invisible target per bucket, a 1px `--border-strong` guide line, and a tooltip panel (surface, strong border, `--text-xs`, a 10 by 2px color key per series). Other bars may dim to 85% opacity. Nothing moves.
11. A legend is a row of 10px square swatches with muted words, under or above the plot.
12. A heatmap or matrix: square cells of at least 30px with a 2px gutter, a letter or glyph in every cell, the hatch pattern for "not run", a 2px `--foreground` ring on hover, sticky row and column headers, vertical column headers when the labels are long.
13. Ranked bars: name, bar, and number in a `10rem 1fr 3.5rem` grid, a 10px tall bar with 2px gaps between segments.
14. A gauge or donut is allowed for one headline ratio only. Draw it with stroke arcs, not with a gradient.
15. SVG elements take their colors from the `ui-chart-*` classes and `data-status` on a parent `<g>`. Do not write colors into SVG attributes.

## 15. Adapting to a stack

### 15.1 Plain HTML

Link `tokens.css`, then `components.css`, then `ui-local.css`, then your page CSS. Load the fonts:

```html
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@400;600;700;800&family=Geist+Mono:wght@400;600;700&display=swap">
```

Set `<meta name="theme-color">` to `#ffffff` for light and `#0a0a0a` for dark.

### 15.2 React with CSS Modules

- `tokens.css` goes in `globals.css`. The component rules go in `ui.module.css` without the `ui-` prefix and with camelCase names (`button`, `buttonPrimary`, `buttonSmall`). Each page has its own `Page.module.css` for layout only.
- With Next.js, load the fonts through `next/font/google` (`Geist`, `Geist_Mono`) and point `--font-sans` and `--font-mono` at the font variables.
- Put the state vocabulary in `src/lib/status.ts` and set `data-status` from it. Do not compute color strings in JSX and do not set colors in inline styles. A bar value goes in the `--value` custom property. Column and input widths may be inline styles.

### 15.3 Tailwind CSS v4

Keep `tokens.css` as the source of truth and expose it to Tailwind:

```css
@import "tailwindcss";
@import "./tokens.css";

@theme inline {
  --color-background: var(--background);
  --color-surface: var(--surface);
  --color-foreground: var(--foreground);
  --color-muted: var(--muted-foreground);
  --color-label: var(--label);
  --color-line: var(--border);
  --color-line-strong: var(--border-strong);
  --color-hover: var(--hover-surface);
  --color-link: var(--link);
  --color-success: var(--success);
  --color-success-text: var(--success-text);
  --color-failure: var(--failure);
  --color-failure-text: var(--failure-text);
  --color-progress: var(--progress);
  --color-progress-text: var(--progress-text);
  --color-warning: var(--warning);
  --color-warning-text: var(--warning-text);
  --color-inactive: var(--inactive);
  --color-inactive-text: var(--inactive-text);
  --color-skipped: var(--skipped);
  --color-skipped-text: var(--skipped-text);
  --color-accent: var(--accent);
  --color-accent-text: var(--accent-text);
}

@theme {
  --radius-*: initial;
  --radius-sm: 2px;
  --shadow-*: initial;
  --inset-shadow-*: initial;
  --drop-shadow-*: initial;
  --animate-*: initial;
}
```

Import `components.css` into the components layer, so a utility class can still adjust a `ui-*` component: `@import "./components.css" layer(components);`. Use `rounded-sm` for every corner. Prefer the `ui-*` classes from `components.css` for buttons, badges, and tables over long utility strings, so the rules stay in one place.

### 15.4 Component libraries (MUI, shadcn/ui, Radix, and others)

Prefer no library. If a project already uses one, flatten it:

- Corner radius 2px, elevation and shadows off, ripple off, transitions off.
- Font families from the tokens. Control sizes that match the app's density (at the default density: MUI `size="small"`, `density: "compact"`).
- MUI derives shades from its palette and cannot read `var()`. Copy the hex values from `tokens.css` into the palette, one theme for light and one for dark.

```ts
const theme = createTheme({
  shape: { borderRadius: 2 },
  shadows: Array(25).fill("none") as Shadows,
  transitions: { create: () => "none" },
  typography: { fontFamily: "var(--font-sans)", fontSize: 13 }, // 13.6px is --text-md at the default density
  components: {
    MuiButtonBase: { defaultProps: { disableRipple: true } },
    MuiPaper: { defaultProps: { elevation: 0 }, styleOverrides: { root: { border: "1px solid var(--border)" } } },
  },
});
```

### 15.5 Phoenix LiveView (Tailwind v4, daisyUI, Heroicons)

A `phx.new` project starts with daisyUI themes, Heroicons, a corner-toast flash, a top loading bar, and an AGENTS.md that asks for micro-interactions. Change it once, at the start:

1. Put `tokens.css` and `components.css` in `assets/css/`. In `app.css`, after `@import "tailwindcss" source(none);` and the `@source` lines, add `@import "./tokens.css";` and `@import "./components.css" layer(components);`.
2. Remove the daisyUI plugin and both `daisyui-theme` blocks. Map the classes: `btn` to `ui-button`, `btn-primary` to `ui-button--primary`, `btn-ghost` to `ui-button--ghost`, `btn-sm` and `btn-xs` to `ui-button--small`, `badge` to `ui-badge`, `table` to `ui-table`, `alert` to `ui-notice`, `input` and `select` to `ui-input` and `ui-select`, `rounded-box border border-base-300 p-4` to `ui-panel`, `text-base-content/60` to `ui-muted`.
3. Rewrite `core_components.ex` so `<.button>`, `<.input>`, `<.table>`, `<.header>`, `<.list>`, and `<.flash>` render the `ui-*` classes. Templates then keep using the core components, as the Phoenix AGENTS.md asks.
4. Keep the `<.icon>` component name, but make it render the glyphs in section 9: `hero-x-mark` ✕, `hero-arrow-up-mini` ↑, `hero-arrow-down-mini` ↓, `hero-arrows-right-left-mini` ⇄, `hero-arrow-path` ↻, `hero-pencil` ✎. For `hero-plus-mini`, write "+ " in the button label instead. Remove the Heroicons plugin when no icon is left.
5. `<.flash_group>` renders `ui-notice` elements at the top of `main` (info to `progress`, error to `failure`), not toasts in a corner. They stay until the user dismisses them or navigates.
6. Remove `topbar.js` (an animated loading bar). For a slow navigation, set `aria-busy="true"` on the content region and show the region overlay (section 7.14).
7. In-flight buttons use `phx-disable-with="Saving…"`. The `phx-click-loading` variants may change a color or the text, never add motion. Remove `animate-*` utilities.
8. The theme script in `root.html.heex` already sets `data-theme` on `<html>`, and the tokens read it (section 2.4). Keep it.
9. A layout that renders output for another audience (an overlay, a widget) gets `data-surface="output"` on its `<html>` (section 0.1), and its own CSS keeps its own design.
10. Tell the user about the AGENTS.md lines that conflict with this guide (section 0.2): "subtle micro-interactions", "smooth transitions", "smooth page transitions", "always use the `<.icon>` component for hero icons".

### 15.6 Terminal output and text reports

The same language applies outside the browser:

- Tables in fixed-width columns, headers in caps, numbers right-aligned.
- State words in caps (`DONE`, `FAILED`) with color from ANSI: green success, red failure, cyan progress, yellow warning, gray inactive, blue skipped. The word is always there without color.
- Glyphs from section 9 (✓ ✕ ⤼ ·), " · " separators, "—" for missing, the formats in section 11.
- A summary line first: the verdict, then the table.

## 16. Review checklist

Run this before you report a UI task as done.

**Files**
- [ ] `tokens.css` and `components.css` are unchanged copies. Project CSS is in `ui-local.css` or page modules.
- [ ] The page shell matches section 5.2: top bar with the square brand mark and mono caps name, micro-label nav, page header with an aside.
- [ ] The density is the default, or the override in `ui-local.css` changes only adjustable tokens (section 2.2) and has a comment with one of the reasons in section 5.1. No color, font, radius, or motion token is overridden.

**Scope**
- [ ] Output for another audience (overlays, documents, emails, widgets) keeps its own design and has `data-surface="output"` if it shares the CSS bundle.
- [ ] Project instructions that conflict with this guide are reported to the user.

**Tokens and color**
- [ ] No hex, rgb, or named color outside `tokens.css` and page-level token blocks. Allowed elsewhere: `transparent`, `currentColor`, and the `theme-color` meta tag.
- [ ] No component-level dark-mode rule. Every color token is `light-dark()`. A theme toggle, if any, sets `data-theme` on `<html>`.
- [ ] A user-chosen color appears only as a `ui-color-swatch`, never in the chrome.
- [ ] Every hue on screen is a state, a link, or focus.
- [ ] Text uses only the text tokens in section 3.2. No fill token as text.
- [ ] States are set with `data-status`, never with per-state classes or inline colors.
- [ ] Text on tinted rows uses `--foreground` or `--muted-on-tint` only. Badges, buttons, and bar tracks there sit on `--surface`.

**Shape and motion**
- [ ] Every radius is 2px, except dots and the inner corners of a segmented control.
- [ ] No `box-shadow` for depth, no gradient except the hatch and the preview checkerboard.
- [ ] No `transform`, width, or height transition. No `@keyframes`. No spinner.

**Type and words**
- [ ] IDs, table numbers, times, sizes, paths, and inputs are mono with tabular figures. Stat and hero numbers, and numbers inside sentences, are sans.
- [ ] Source text is sentence case. CSS does the uppercase.
- [ ] One word per state, from one module.
- [ ] "…" not "...". " · " separators. "—" for missing.
- [ ] Empty states say what to change. Errors say what failed and give a way out.

**Behavior**
- [ ] Filters, sort, and page are in the URL. Back works.
- [ ] A refresh does not blank or move the screen.
- [ ] Every destructive action asks first and names the count.
- [ ] Disabled controls explain themselves in `title`.

**Accessibility**
- [ ] Skip link, landmarks, `aria-current` in nav.
- [ ] Visible focus on every control.
- [ ] States have a word, letter, or glyph, not only a color.
- [ ] Progress bars, charts, and live regions have their roles and labels.
- [ ] Targets are at least 24px (44px on touch-first screens).
- [ ] The page works in light and dark mode (check both).
- [ ] The contrast audit (appendix B) returns `[]` in light mode and in dark mode.
- [ ] No horizontal page scroll at 375px wide. Wide tables scroll inside `ui-table-wrap`.

## Appendix A. components.css

<!-- file: components.css -->
```css
/* Laggish design guide components. Requires tokens.css. Flat selectors, no nesting. */

/* ---------- Base ---------- */

*,
*::before,
*::after {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

html,
body {
  height: 100%;
}

html:not([data-surface="output"]) body {
  color: var(--foreground);
  background: var(--background);
  font-family: var(--font-sans);
  font-size: var(--text-md);
  line-height: 1.4;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}

a {
  color: inherit;
  text-decoration: none;
}

button,
input,
select,
textarea {
  font: inherit;
  color: inherit;
}

:focus-visible {
  outline: 3px solid var(--focus);
  outline-offset: 2px;
}

input[type="checkbox"],
input[type="radio"] {
  width: 0.9rem;
  height: 0.9rem;
  accent-color: var(--foreground);
}

@media (pointer: coarse) {
  input[type="checkbox"],
  input[type="radio"] {
    width: 1.25rem;
    height: 1.25rem;
  }
}

@media (prefers-reduced-motion: reduce) {
  *,
  *::before,
  *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
  }
}

.ui-skip-link {
  position: absolute;
  top: -100%;
  left: 0;
  z-index: 1000;
  padding: 0.75rem 1.5rem;
  background: var(--foreground);
  color: var(--background);
  font-size: var(--text-lg);
  text-decoration: underline;
}

.ui-skip-link:focus {
  top: 0;
}

.ui-sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  margin: -1px;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  white-space: nowrap;
  border: 0;
}

/* ---------- State ---------- */

[data-status="success"]  { --state: var(--success);  --state-text: var(--success-text); }
[data-status="failure"]  { --state: var(--failure);  --state-text: var(--failure-text); }
[data-status="progress"] { --state: var(--progress); --state-text: var(--progress-text); }
[data-status="warning"]  { --state: var(--warning);  --state-text: var(--warning-text); }
[data-status="inactive"] { --state: var(--inactive); --state-text: var(--inactive-text); }
[data-status="skipped"]  { --state: var(--skipped);  --state-text: var(--skipped-text); }
[data-status="accent"]   { --state: var(--accent);   --state-text: var(--accent-text); }
[data-status="neutral"]  { --state: color-mix(in srgb, var(--foreground) 24%, transparent); --state-text: var(--muted-foreground); }

/* Stop a child from following its parent's state */
[data-status="none"] { --state: initial; --state-text: initial; }

/* An inactive object that keeps its outcome */
[data-status="inactive"][data-outcome="success"] { --state: color-mix(in srgb, var(--success) 40%, var(--inactive)); }
[data-status="inactive"][data-outcome="failure"] { --state: color-mix(in srgb, var(--failure) 40%, var(--inactive)); }

/* 45% state tint on an opaque surface (row, tile) */
.ui-tint[data-status] {
  background-color: color-mix(in srgb, var(--state) 45%, var(--surface));
}

.ui-tint .ui-label,
.ui-tint .ui-card-id,
.ui-tint .ui-muted,
.ui-tint .ui-sep,
.ui-tint .ui-field-label,
.ui-tint .ui-stat-label,
.ui-tint .ui-spec dt,
.ui-tint .ui-hint,
.ui-tint .ui-age {
  color: var(--muted-on-tint);
}

/* State colors and link blue drop below 4.5:1 on a tint: use the foreground */
.ui-tint .ui-link,
.ui-tint .ui-button-link,
.ui-tint .ui-quiet-link:hover,
.ui-tint .ui-hint--warning,
.ui-tint .ui-hint--error,
.ui-tint .ui-required,
.ui-tint .ui-expiring,
.ui-tint .ui-age[data-stale] {
  color: var(--foreground);
}

/* Badges and buttons on a tint sit on the surface, or their text drops below 4.5:1 */
.ui-tint .ui-badge,
.ui-tint .ui-progress,
.ui-tint .ui-button:not(.ui-button--primary) {
  background: var(--surface);
}


/* ---------- Text ---------- */

.ui-label {
  font-size: var(--text-xs);
  font-weight: 600;
  line-height: 1.2;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: var(--label);
}

.ui-mono {
  font-family: var(--font-mono);
  font-variant-numeric: tabular-nums;
}

.ui-num {
  font-variant-numeric: tabular-nums;
}

.ui-muted {
  color: var(--muted-foreground);
}

.ui-sep {
  margin: 0 0.3rem;
  color: var(--label);
  user-select: none;
}

.ui-truncate {
  display: block;
  min-width: 0;
  max-width: 100%;
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
}

.ui-truncate[role="button"] {
  cursor: pointer;
}

.ui-truncate[aria-expanded="true"] {
  white-space: normal;
  overflow: visible;
  overflow-wrap: anywhere;
}

.ui-clamp {
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: var(--clamp-lines, 2);
  line-clamp: var(--clamp-lines, 2);
  overflow: hidden;
  white-space: normal;
}

/* ---------- Links ---------- */

.ui-link {
  color: var(--link);
  text-decoration: underline;
  text-underline-offset: 2px;
}

.ui-link:hover {
  text-decoration: none;
}

.ui-id-link {
  font-family: var(--font-mono);
  font-weight: 600;
  color: var(--foreground);
  text-decoration: underline;
  text-decoration-color: var(--border);
  text-underline-offset: 3px;
}

.ui-id-link:hover {
  text-decoration-color: var(--foreground);
}

/* A name or owner that links: plain until hover */
.ui-quiet-link {
  color: inherit;
}

.ui-quiet-link:hover {
  color: var(--link);
  text-decoration: underline;
  text-underline-offset: 2px;
}

/* ---------- Page shell ---------- */

.ui-shell {
  display: flex;
  flex-direction: column;
  min-height: 100vh;
  min-height: 100dvh;
}

.ui-shell--fill {
  height: 100vh;
  height: 100dvh;
  overflow: hidden;
}

.ui-topbar {
  display: flex;
  flex-shrink: 0;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.25rem 1rem;
  min-height: var(--topbar-height);
  padding: 0 var(--page-pad-x);
  background: var(--surface);
  border-bottom: 1px solid var(--border);
}

.ui-brand {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  font-family: var(--font-mono);
  font-size: var(--text-sm);
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  white-space: nowrap;
  color: var(--foreground);
}

.ui-brand-mark {
  width: 0.55rem;
  height: 0.55rem;
  background: var(--foreground);
}

.ui-sitenav {
  display: inline-flex;
  flex-wrap: wrap;
  align-items: center;
  gap: clamp(0.5rem, 1vw, 0.75rem);
}

.ui-sitenav a {
  display: inline-flex;
  align-items: center;
  min-height: 1.5rem;
  font-size: var(--text-xs);
  font-weight: 600;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: var(--label);
  text-decoration: underline;
  text-underline-offset: 2px;
  transition: color var(--duration-color) ease;
}

.ui-sitenav a:hover {
  color: var(--link);
  text-decoration: none;
}

.ui-sitenav a[aria-current="page"] {
  color: var(--foreground);
  text-decoration: none;
  cursor: default;
}

.ui-topbar-aside {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  min-width: 0;
  margin-left: auto;
  font-size: var(--text-sm);
  color: var(--muted-foreground);
}

.ui-main {
  display: flex;
  flex: 1;
  flex-direction: column;
  width: 100%;
  min-height: 0;
  padding: var(--page-pad-y) var(--page-pad-x);
}

.ui-shell--fill .ui-main {
  overflow: hidden;
}

.ui-page-header {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.75rem;
  margin-bottom: 0.5rem;
}

.ui-title {
  font-size: var(--text-lg);
  font-weight: 700;
  line-height: 1.25;
  letter-spacing: -0.01em;
}

.ui-title-aside {
  display: inline-flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.5rem;
  font-size: var(--text-sm);
  color: var(--muted-foreground);
}

.ui-subnav {
  display: flex;
  flex-wrap: wrap;
  gap: 0.35rem;
  margin-bottom: 0.6rem;
}

.ui-toolbar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.5rem;
  padding: 0.35rem 0 0.5rem;
  margin-bottom: 0.5rem;
  border-bottom: 1px solid var(--border);
}

.ui-toolbar--sticky {
  position: sticky;
  top: 0;
  z-index: 3;
  background: var(--background);
}

.ui-toolbar-end {
  display: inline-flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.35rem;
  margin-left: auto;
}

.ui-age {
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

.ui-age[data-stale] {
  color: var(--warning-text);
}

/* ---------- Panel ---------- */

.ui-panel {
  min-width: 0;
  padding: 0.5rem;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
}

.ui-panel--strong {
  border-color: var(--border-strong);
}

.ui-panel-title {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem;
  margin: 0 0 0.35rem;
  font-size: var(--text-xs);
  font-weight: 600;
  line-height: 1.2;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: var(--label);
}

.ui-panel-title-aside {
  margin-left: auto;
  font-weight: 400;
  letter-spacing: 0;
  text-transform: none;
  color: var(--muted-foreground);
}

/* ---------- Buttons ---------- */

.ui-button {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 0.35rem;
  min-height: var(--control-h);
  padding: 0.25rem 0.6rem;
  font-family: var(--font-sans);
  font-size: var(--text-sm);
  font-weight: 600;
  line-height: 1;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  white-space: nowrap;
  color: var(--foreground);
  background: transparent;
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
  cursor: pointer;
  appearance: none;
  transition:
    background-color var(--duration-color) ease,
    color var(--duration-color) ease,
    border-color var(--duration-color) ease,
    opacity var(--duration-color) ease;
}

.ui-button:hover:not(:disabled) {
  background: var(--foreground);
  color: var(--background);
}

.ui-button:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

.ui-button--primary {
  background: var(--foreground);
  color: var(--background);
}

.ui-button--primary:hover:not(:disabled) {
  opacity: 0.85;
}

.ui-button--danger {
  border-color: var(--failure);
  color: var(--failure-text);
}

.ui-button--danger:hover:not(:disabled) {
  background: var(--failure);
  border-color: var(--failure);
  color: var(--on-fill);
}

.ui-button--quiet {
  border-color: var(--border);
  color: var(--muted-foreground);
}

.ui-button--ghost {
  border-color: transparent;
  color: var(--muted-foreground);
}

.ui-button--ghost:hover:not(:disabled) {
  background: var(--hover-surface);
  color: var(--foreground);
}

.ui-button--compact {
  min-height: var(--control-h-compact);
  padding: 0.15rem 0.5rem;
}

.ui-button--small {
  min-height: var(--control-h-sm);
  min-width: var(--control-h-sm);
  padding: 0.1rem 0.45rem;
}

.ui-button-link {
  padding: 0;
  font: inherit;
  color: var(--link);
  background: none;
  border: 0;
  text-decoration: underline;
  text-underline-offset: 2px;
  cursor: pointer;
}

.ui-button-link:hover {
  text-decoration: none;
}

.ui-button-group {
  display: inline-flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.35rem;
}

/* ---------- Chips and segmented control ---------- */

.ui-chip {
  position: relative;
  display: inline-flex;
  align-items: center;
  gap: 0.3rem;
  min-height: var(--control-h-sm);
  padding: 0.18rem 0.5rem;
  font-family: var(--font-sans);
  font-size: var(--text-xs);
  font-weight: 600;
  line-height: 1;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  white-space: nowrap;
  color: var(--muted-foreground);
  background: transparent;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  cursor: pointer;
  appearance: none;
  transition:
    background-color var(--duration-color) ease,
    color var(--duration-color) ease,
    border-color var(--duration-color) ease;
}

.ui-chip:hover:not(:disabled) {
  z-index: 1;
  color: var(--foreground);
  border-color: var(--border-strong);
}

.ui-chip[aria-pressed="true"],
.ui-chip[aria-checked="true"],
.ui-chip[aria-current="true"],
.ui-chip[aria-current="page"] {
  z-index: 1;
  color: var(--background);
  background: var(--foreground);
  border-color: var(--foreground);
}

.ui-chip:focus-visible {
  z-index: 2;
}

.ui-chip:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

.ui-segmented {
  display: inline-flex;
}

.ui-segmented > * {
  border-radius: 0;
}

.ui-segmented > :first-child {
  border-radius: var(--radius) 0 0 var(--radius);
}

.ui-segmented > :last-child {
  border-radius: 0 var(--radius) var(--radius) 0;
}

.ui-segmented > :not(:first-child) {
  margin-left: -1px;
}

/* ---------- Badges and dots ---------- */

.ui-badge {
  display: inline-flex;
  align-items: center;
  gap: 0.3rem;
  padding: 0.1rem 0.4rem;
  font-size: var(--text-xs);
  font-weight: 700;
  line-height: 1.2;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  white-space: nowrap;
  color: var(--state-text, var(--muted-foreground));
  background: light-dark(
    color-mix(in srgb, var(--state, var(--label)) 25%, transparent),
    color-mix(in srgb, var(--state, var(--label)) 16%, transparent)
  );
  border-radius: var(--radius);
}

.ui-badge--data {
  font-family: var(--font-mono);
  font-weight: 600;
  letter-spacing: 0;
  text-transform: none;
  font-variant-numeric: tabular-nums;
}

a.ui-badge {
  transition:
    background-color var(--duration-color) ease,
    color var(--duration-color) ease;
}

a.ui-badge:hover {
  color: var(--background);
  background: var(--state-text, var(--foreground));
}

.ui-dot {
  flex: none;
  width: 0.5rem;
  height: 0.5rem;
  background: var(--state-text, var(--label));
  border-radius: 50%;
}

/* ---------- Stats ---------- */

.ui-stats {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  justify-content: center;
  gap: clamp(0.75rem, 2vw, 1.5rem);
}

.ui-stat {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 0.25rem;
  line-height: 1;
}

.ui-stat-value {
  font-size: var(--text-xl);
  font-weight: 800;
  letter-spacing: -0.02em;
  font-variant-numeric: tabular-nums;
  color: var(--state-text, var(--foreground));
}

.ui-stat-label {
  font-size: var(--text-xs);
  font-weight: 600;
  line-height: 1.2;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: var(--label);
}

.ui-stat-divider {
  align-self: stretch;
  width: 1px;
  background: var(--border);
}

.ui-hero {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.ui-hero-value {
  font-size: var(--text-hero);
  font-weight: 800;
  line-height: 1;
  letter-spacing: -0.02em;
  font-variant-numeric: tabular-nums;
  color: var(--state-text, var(--foreground));
}

.ui-verdict {
  max-width: 34rem;
  font-size: var(--text-sm);
  line-height: 1.45;
  color: var(--muted-foreground);
}

.ui-verdict strong {
  color: var(--foreground);
}

/* ---------- Fields ---------- */

.ui-field {
  display: flex;
  flex-direction: column;
  gap: 0.2rem;
  min-width: 0;
}

.ui-field--inline {
  flex-direction: row;
  align-items: center;
  gap: 0.35rem;
}

.ui-field-row {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-end;
  gap: 0.5rem;
}

.ui-field-row > * {
  flex: 1 1 8rem;
}

.ui-field-label {
  font-size: var(--text-xs);
  font-weight: 600;
  line-height: 1.2;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  white-space: nowrap;
  color: var(--label);
}

.ui-required {
  margin-left: 0.15rem;
  color: var(--failure-text);
}

.ui-input,
.ui-select,
.ui-textarea {
  width: 100%;
  min-height: var(--control-h);
  padding: 0.2rem 0.4rem;
  font-family: var(--font-mono);
  font-size: var(--text-md);
  line-height: 1.3;
  color: var(--foreground);
  background: var(--surface);
  border: 1px solid var(--border-input);
  border-radius: var(--radius);
}

.ui-select {
  cursor: pointer;
}

.ui-textarea {
  min-height: 4rem;
  resize: vertical;
}

.ui-input::placeholder,
.ui-textarea::placeholder {
  color: var(--placeholder);
}

.ui-input:focus,
.ui-select:focus,
.ui-textarea:focus {
  border-color: var(--foreground);
  outline: 2px solid var(--focus);
  outline-offset: 1px;
}

.ui-input[aria-invalid="true"],
.ui-select[aria-invalid="true"],
.ui-textarea[aria-invalid="true"] {
  border-color: var(--failure-text);
}

.ui-input:disabled,
.ui-select:disabled,
.ui-textarea:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.ui-input--compact,
.ui-select.ui-input--compact {
  min-height: var(--control-h-compact);
  padding: 0.15rem 0.35rem;
}

.ui-hint {
  font-size: var(--text-xs);
  color: var(--muted-foreground);
}

.ui-hint--warning {
  color: var(--warning-text);
}

.ui-hint--error {
  color: var(--failure-text);
}

/* ---------- Notices, empty, loading ---------- */

.ui-notice {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.35rem 0.6rem;
  font-size: var(--text-md);
  color: var(--state-text, var(--foreground));
  background: color-mix(in srgb, var(--state, transparent) 14%, var(--surface));
  border: 1px solid var(--border);
  border-left: var(--rail) solid var(--state, var(--border-strong));
  border-radius: var(--radius);
}

.ui-notice-end {
  margin-left: auto;
}

.ui-empty {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 0.5rem;
  padding: 1rem;
  font-size: var(--text-md);
  text-align: center;
  color: var(--muted-foreground);
  border: 1px dashed var(--border);
  border-radius: var(--radius);
}

.ui-loading {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 6rem;
  font-size: var(--text-md);
  color: var(--muted-foreground);
}

.ui-region {
  position: relative;
  min-height: 6rem;
}

.ui-region-overlay {
  position: absolute;
  inset: 0;
  z-index: 5;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: var(--text-md);
  background: color-mix(in srgb, var(--background) 70%, transparent);
}

.ui-placeholder-bar {
  height: 0.75rem;
  background: var(--hover-surface);
  border-radius: var(--radius);
}

/* ---------- Table ---------- */

/* The wrap is the scroll container on both axes, so the header can stick inside it */
.ui-table-wrap {
  max-height: var(--table-max-h, calc(100dvh - 10rem));
  overflow: auto;
  border: 1px solid var(--border);
  border-radius: var(--radius);
}

/* In a fill-viewport pane: take the pane's height instead */
.ui-table-wrap--fill {
  flex: 1;
  min-height: 0;
  max-height: none;
}

.ui-table {
  width: 100%;
  border-collapse: collapse;
  font-size: var(--text-sm);
}

.ui-table th {
  position: sticky;
  top: 0;
  z-index: 2;
  padding: 0.3rem 0.45rem;
  font-size: var(--text-xs);
  font-weight: 600;
  line-height: 1.2;
  letter-spacing: 0.05em;
  text-align: left;
  text-transform: uppercase;
  white-space: nowrap;
  color: var(--label);
  background: var(--surface);
  border-bottom: 1px solid var(--border-strong);
}

.ui-table td {
  height: var(--row-h);
  padding: 0.25rem 0.45rem;
  white-space: nowrap;
  vertical-align: middle;
  border-bottom: 1px solid var(--border);
}

.ui-table td.ui-cell-wrap {
  min-width: 12rem;
  white-space: normal;
}

.ui-table .ui-button-group {
  flex-wrap: nowrap;
}

/* Truncation inside an auto-width table needs a cap */
.ui-table td .ui-truncate {
  max-width: var(--cell-max, 20rem);
}

/* Fixed layout for resizable columns: widths come from <col> or th widths */
.ui-table--fixed {
  table-layout: fixed;
}

.ui-table--fixed td .ui-truncate {
  max-width: 100%;
}

.ui-table tbody tr:last-child td {
  border-bottom: none;
}

.ui-table tbody tr:hover {
  background-color: var(--hover-surface);
}

.ui-table tbody tr.ui-tint[data-status]:hover {
  background-color: color-mix(in srgb, var(--state) 55%, var(--surface));
}

.ui-table .ui-cell-num,
.ui-table th.ui-cell-num {
  text-align: right;
  font-variant-numeric: tabular-nums;
}

.ui-table .ui-cell-mono {
  font-family: var(--font-mono);
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

.ui-table tr[aria-current="true"] td {
  font-weight: 600;
  background-color: var(--hover-surface);
}

.ui-table tr[aria-current="true"] td:first-child {
  border-left: var(--rail) solid var(--state, var(--progress));
}

.ui-table tr[data-selected] td {
  background-color: color-mix(in srgb, var(--foreground) 10%, var(--surface));
}

/* A row that needs attention without a full tint: 14% tint and a rail */
.ui-table tr.ui-flag[data-status] td {
  color: var(--state-text);
  background-color: color-mix(in srgb, var(--state) 14%, var(--surface));
}

.ui-table tr.ui-flag[data-status] td:first-child {
  border-left: var(--rail) solid var(--state);
}

.ui-table tr.ui-past td {
  color: var(--muted-foreground);
}

.ui-table tr.ui-group-row td {
  font-weight: 600;
  background-color: var(--hover-surface);
  border-top: 1px solid var(--border-strong);
}

.ui-sort {
  display: inline-flex;
  align-items: center;
  gap: 0.25rem;
  min-height: 1.5rem;
  padding: 0;
  font: inherit;
  letter-spacing: inherit;
  text-transform: inherit;
  white-space: nowrap;
  color: inherit;
  background: none;
  border: 0;
  cursor: pointer;
}

.ui-row-name {
  font-weight: 600;
}

.ui-expiring {
  font-weight: 600;
  color: var(--warning-text);
}

.ui-th-resizable {
  position: relative;
}

.ui-resize-handle {
  position: absolute;
  top: 0;
  right: 0;
  bottom: 0;
  width: 6px;
  cursor: col-resize;
}

.ui-resize-handle::after {
  content: "";
  position: absolute;
  top: 0;
  right: 2px;
  bottom: 0;
  width: 2px;
  background: var(--border);
}

.ui-resize-handle:hover::after {
  background: var(--link);
}

.ui-sort:hover {
  color: var(--link);
  text-decoration: underline;
  text-underline-offset: 2px;
}

/* ---------- Progress ---------- */

.ui-progress {
  position: relative;
  height: 0.5rem;
  overflow: hidden;
  background: var(--hover-surface);
  border-radius: var(--radius);
}

.ui-progress--labeled {
  height: 1.1rem;
}

.ui-progress-fill {
  width: var(--value, 0%);
  height: 100%;
  background: var(--state, var(--progress));
}

.ui-progress-label {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  font-family: var(--font-mono);
  font-size: var(--text-xs);
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
  color: var(--foreground);
  pointer-events: none;
}

.ui-progress-label--on-fill {
  color: var(--on-fill);
  clip-path: inset(0 calc(100% - var(--value, 0%)) 0 0);
}

/* ---------- Status cards and tiles ---------- */

.ui-cards {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(clamp(18rem, 28vw, 26rem), 1fr));
  grid-auto-rows: 1fr;
  gap: 0.5rem;
  list-style: none;
}

.ui-card {
  display: flex;
  flex-direction: column;
  min-width: 0;
  height: 100%;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
}

.ui-card-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem;
  padding: 0.3rem 0.5rem;
  background: var(--hover-surface);
  border-bottom: 1px solid var(--border);
}

.ui-card-id {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  min-width: 0;
  font-family: var(--font-mono);
  font-size: var(--text-sm);
  white-space: nowrap;
  color: var(--label);
}

.ui-card-body {
  display: flex;
  flex: 1;
  flex-direction: column;
  gap: 0.4rem;
  min-width: 0;
  padding: 0.5rem;
}

.ui-card-title {
  font-size: var(--text-md);
  font-weight: 700;
  line-height: 1.25;
}

a.ui-card-title:hover {
  color: var(--link);
  text-decoration: underline;
}

.ui-card-meta {
  font-size: var(--text-sm);
  color: var(--muted-foreground);
}

.ui-card-progress {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.ui-card-progress-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.5rem;
  min-width: 0;
  font-size: var(--text-sm);
}

.ui-card-progress-head > .ui-mono {
  flex-shrink: 0;
  font-weight: 600;
  color: var(--muted-foreground);
}

.ui-card-footer {
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 0.25rem;
  margin-top: auto;
  padding: 0.3rem 0.5rem;
  border-top: 1px solid var(--border);
}

.ui-tiles {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(clamp(8rem, 28vw, 11rem), 1fr));
  grid-auto-rows: 1fr;
  gap: 0.35rem;
  list-style: none;
}

.ui-tile {
  display: flex;
  flex-direction: column;
  gap: 0.2rem;
  min-width: 0;
  padding: 0.4rem 0.5rem;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
}

.ui-tile .ui-progress {
  margin-top: auto;
}

/* ---------- Spec list and key-value list ---------- */

.ui-spec {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4rem 1rem;
  padding-top: 0.4rem;
  border-top: 1px solid var(--border);
}

.ui-spec > div {
  display: flex;
  flex-direction: column;
  gap: 0.1rem;
  min-width: 0;
}

.ui-spec dt,
.ui-kv dt {
  font-size: var(--text-xs);
  font-weight: 600;
  line-height: 1.2;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: var(--label);
}

.ui-spec dd {
  font-family: var(--font-mono);
  font-size: var(--text-sm);
  font-variant-numeric: tabular-nums;
}

.ui-kv {
  display: grid;
  grid-template-columns: 9rem 1fr;
}

.ui-kv dt,
.ui-kv dd {
  padding: 0.3rem 0;
  border-bottom: 1px solid var(--border);
}

.ui-kv dt {
  padding-right: 0.5rem;
  align-self: stretch;
}

.ui-kv dd {
  min-width: 0;
  font-family: var(--font-mono);
  font-size: var(--text-sm);
  overflow-wrap: anywhere;
}

/* ---------- Disclosure and menu ---------- */

.ui-disclosure > summary {
  display: flex;
  align-items: center;
  gap: 0.35rem;
  min-height: 1.5rem;
  padding: 0.2rem 0;
  font-size: var(--text-xs);
  font-weight: 600;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: var(--label);
  list-style: none;
  cursor: pointer;
}

.ui-disclosure > summary::-webkit-details-marker {
  display: none;
}

.ui-disclosure > summary::before {
  content: "\25B8" / "";
}

.ui-disclosure[open] > summary::before {
  content: "\25BE" / "";
}

.ui-disclosure > summary:hover {
  color: var(--foreground);
}

.ui-menu {
  position: relative;
  display: inline-block;
}

.ui-menu > summary {
  list-style: none;
}

.ui-menu > summary::-webkit-details-marker {
  display: none;
}

.ui-menu-panel {
  position: absolute;
  top: calc(100% + 0.25rem);
  right: 0;
  z-index: 20;
  display: grid;
  gap: 0.25rem;
  min-width: 12rem;
  padding: 0.5rem;
  font-size: var(--text-sm);
  background: var(--background);
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
}

.ui-menu-panel label {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  white-space: nowrap;
}

/* ---------- Dialog ---------- */

.ui-dialog {
  width: min(720px, calc(100% - 1rem));
  max-width: none;
  max-height: calc(100dvh - 2rem);
  margin: 1rem auto auto;
  padding: 0;
  color: var(--foreground);
  background: var(--surface);
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
}

.ui-dialog::backdrop {
  background: var(--backdrop);
}

.ui-dialog-header {
  position: sticky;
  top: 0;
  z-index: 2;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem;
  padding: 0.4rem 0.6rem;
  background: var(--surface);
  border-bottom: 1px solid var(--border-strong);
}

.ui-dialog-title {
  font-size: var(--text-md);
  font-weight: 600;
  line-height: 1.3;
  overflow-wrap: anywhere;
}

.ui-dialog-body {
  padding: 0.25rem 0.6rem 0.5rem;
}

.ui-dialog-footer {
  display: flex;
  justify-content: flex-end;
  gap: 0.35rem;
  padding: 0.4rem 0.6rem;
  border-top: 1px solid var(--border);
}

/* ---------- Log viewer and code ---------- */

.ui-log {
  display: flex;
  flex-direction: column;
  min-height: 0;
  border: 1px solid var(--border);
  border-radius: var(--radius);
}

.ui-log-toolbar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.5rem;
  padding: 0.2rem 0.4rem;
  background: var(--hover-surface);
  border-bottom: 1px solid var(--border);
}

.ui-log-meta {
  font-family: var(--font-mono);
  font-size: var(--text-xs);
  font-weight: 600;
  color: var(--label);
}

.ui-log-body {
  flex: 1;
  min-height: 0;
  margin: 0;
  padding: 0.3rem 0.4rem;
  overflow-y: auto;
  font-family: var(--font-mono);
  font-size: var(--text-xs);
  line-height: 1.4;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
}

.ui-log-line {
  display: block;
}

.ui-log-line--highlight {
  margin: 0 -0.4rem;
  padding: 0 0.4rem;
  background: color-mix(in srgb, var(--progress) 15%, transparent);
}

.ui-log-line--dim {
  opacity: 0.25;
}

.ui-log-empty {
  font-style: italic;
  color: var(--label);
}

.ui-pre {
  max-height: 24rem;
  margin: 0;
  padding: 0.35rem 0.5rem;
  overflow: auto;
  font-family: var(--font-mono);
  font-size: var(--text-xs);
  line-height: 1.5;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  background: var(--hover-surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
}

/* ---------- Sticky action bar ---------- */

.ui-actionbar {
  position: sticky;
  bottom: 0;
  z-index: 3;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.35rem;
  padding: 0.4rem 0;
  background: var(--background);
  border-top: 1px solid var(--border);
}

.ui-actionbar-end {
  margin-left: auto;
}

/* ---------- Charts ---------- */

.ui-chart-wrap {
  position: relative;
}

.ui-chart {
  display: block;
  width: 100%;
  height: auto;
  overflow: visible;
  font-family: var(--font-mono);
  font-size: var(--text-2xs);
}

.ui-chart text {
  fill: var(--label);
  font-variant-numeric: tabular-nums;
}

.ui-chart-grid {
  stroke: var(--border);
  stroke-width: 1;
  shape-rendering: crispEdges;
}

.ui-chart-guide {
  stroke: var(--border-strong);
  stroke-width: 1;
  shape-rendering: crispEdges;
}

.ui-chart-line {
  fill: none;
  stroke: var(--state-text, var(--foreground));
  stroke-width: 2;
  stroke-linejoin: round;
  stroke-linecap: round;
}

.ui-chart-area {
  fill: var(--state-text, var(--foreground));
  fill-opacity: 0.12;
  stroke: none;
}

.ui-chart-dot {
  fill: var(--state-text, var(--foreground));
}

.ui-chart-dot--empty {
  fill: var(--surface);
  stroke: var(--label);
  stroke-width: 1;
}

.ui-chart-bar {
  fill: var(--state, var(--inactive));
}

.ui-tooltip {
  position: absolute;
  z-index: 2;
  min-width: 9rem;
  padding: 0.3rem 0.45rem;
  font-size: var(--text-xs);
  pointer-events: none;
  background: var(--surface);
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
}

.ui-tooltip-row {
  display: flex;
  align-items: center;
  gap: 0.35rem;
}

.ui-tooltip-row .ui-mono {
  margin-left: auto;
}

.ui-legend {
  display: flex;
  flex-wrap: wrap;
  gap: 0.75rem;
  font-size: var(--text-xs);
  color: var(--muted-foreground);
}

.ui-legend-item {
  display: inline-flex;
  align-items: center;
  gap: 0.3rem;
}

.ui-swatch {
  flex: none;
  width: 10px;
  height: 10px;
  background: var(--state, var(--inactive));
  border-radius: var(--radius);
}

.ui-swatch--line {
  height: 2px;
  background: var(--state-text, var(--foreground));
  border-radius: 0;
}

.ui-hatch,
.ui-heat-cell.ui-hatch,
.ui-swatch.ui-hatch {
  background: repeating-linear-gradient(135deg, var(--hatch-a) 0 3px, var(--hatch-b) 3px 6px);
}

.ui-heatmap {
  border-collapse: separate;
  border-spacing: 2px;
}

.ui-heatmap thead th {
  position: sticky;
  top: 0;
  z-index: 2;
  background: var(--surface);
}

.ui-heatmap tbody th {
  position: sticky;
  left: 0;
  z-index: 1;
  background: var(--surface);
}

.ui-heatmap th {
  padding: 0 0.35rem;
  font-size: var(--text-xs);
  font-weight: 600;
  text-align: left;
  white-space: nowrap;
  color: var(--label);
}

.ui-heat-cell {
  width: 1.9rem;
  min-width: 1.9rem;
  height: 1.9rem;
  font-family: var(--font-mono);
  font-size: var(--text-xs);
  font-weight: 700;
  text-align: center;
  color: var(--on-fill);
  background: var(--state, var(--hover-surface));
  border-radius: var(--radius);
}

.ui-heat-cell:not([data-status]),
.ui-heat-cell[data-status="neutral"],
.ui-heat-cell[data-status="none"] {
  color: var(--foreground);
}

.ui-heat-cell[data-status="accent"] {
  color: var(--background);
  background: var(--accent-text);
}

.ui-heat-cell:hover {
  outline: 2px solid var(--foreground);
  outline-offset: -2px;
}

.ui-rank {
  display: grid;
  grid-template-columns: 10rem 1fr 3.5rem;
  align-items: center;
  gap: 0.5rem;
  padding: 0.15rem 0.25rem;
  font-size: var(--text-sm);
}

.ui-rank:hover {
  background: var(--hover-surface);
}

.ui-rank-track {
  display: flex;
  gap: 2px;
  height: 10px;
}

.ui-rank-track > span {
  height: 100%;
  background: var(--state, var(--inactive));
}

.ui-rank > .ui-mono {
  text-align: right;
}
/* ---------- Split panes (fill-viewport pages) ---------- */

.ui-split {
  display: grid;
  flex: 1;
  grid-template-columns: minmax(260px, 1fr) minmax(0, 2.5fr);
  gap: 0.35rem;
  min-height: 0;
}

.ui-pane {
  display: flex;
  flex-direction: column;
  min-width: 0;
  min-height: 0;
  overflow-y: auto;
}

@media (max-width: 900px) {
  .ui-split {
    grid-template-columns: 1fr;
    overflow-y: auto;
  }

  .ui-pane {
    overflow: visible;
  }
}

/* ---------- Tabs (sibling panels inside one region) ---------- */

.ui-tabs {
  display: flex;
  overflow-x: auto;
  border-bottom: 1px solid var(--border);
}

.ui-tab {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  min-height: var(--control-h-sm);
  margin-bottom: -1px;
  padding: 0.2rem 0.6rem;
  font-family: var(--font-sans);
  font-size: var(--text-xs);
  font-weight: 600;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  white-space: nowrap;
  color: var(--muted-foreground);
  background: none;
  border: 0;
  border-bottom: 2px solid transparent;
  cursor: pointer;
  transition:
    color var(--duration-color) ease,
    border-color var(--duration-color) ease;
}

.ui-tab:hover {
  color: var(--foreground);
}

.ui-tab[aria-selected="true"] {
  color: var(--foreground);
  border-bottom-color: var(--foreground);
}

.ui-tab-count {
  padding: 0 0.3rem;
  font-family: var(--font-mono);
  font-variant-numeric: tabular-nums;
  letter-spacing: 0;
  border: 1px solid var(--border);
  border-radius: var(--radius);
}

.ui-tab[aria-selected="true"] .ui-tab-count {
  color: var(--background);
  background: var(--foreground);
  border-color: var(--foreground);
}

/* ---------- Pagination ---------- */

.ui-pagination {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 0.35rem;
  padding: 0.4rem 0;
  font-size: var(--text-sm);
}

.ui-pagination-status {
  padding: 0 0.35rem;
  font-family: var(--font-mono);
  font-variant-numeric: tabular-nums;
  color: var(--muted-foreground);
}

/* ---------- Filter builder ---------- */

.ui-filter-rows {
  display: grid;
  gap: 0.35rem;
}

.ui-filter-row {
  display: grid;
  grid-template-columns: minmax(8rem, 12rem) minmax(5rem, 7rem) minmax(9rem, 16rem) auto;
  align-items: center;
  gap: 0.35rem;
}

@media (max-width: 640px) {
  .ui-filter-row {
    grid-template-columns: 1fr 1fr;
  }
}

/* ---------- Form blockers ---------- */

.ui-blockers {
  display: flex;
  flex-direction: column;
  gap: 0.15rem;
  margin-top: 0.35rem;
  padding-left: 1rem;
  font-size: var(--text-xs);
  color: var(--failure-text);
}

/* ---------- Full-page states (not found, unreachable, no access) ---------- */

.ui-page-state {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 0.5rem;
  min-height: 60vh;
  padding: 0.5rem;
  text-align: center;
}

.ui-page-state-title {
  font-size: var(--text-lg);
  font-weight: 700;
  color: var(--state-text, var(--foreground));
}

.ui-page-state p {
  max-width: 40rem;
  color: var(--muted-foreground);
  overflow-wrap: anywhere;
}

/* ---------- Alt-click targets ---------- */

[data-alt-held] .ui-alt-target {
  color: var(--link);
  text-decoration: underline dashed;
  text-underline-offset: 2px;
}

/* ---------- Live controls, output preview, user colors ---------- */

.ui-stepper {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
}

.ui-stepper-value {
  min-width: 2ch;
  font-family: var(--font-mono);
  font-size: var(--text-lg);
  font-weight: 700;
  text-align: center;
  font-variant-numeric: tabular-nums;
}

.ui-preview {
  position: relative;
  width: 100%;
  aspect-ratio: var(--preview-ratio, 16 / 9);
  overflow: hidden;
  border: 1px solid var(--border);
  border-radius: var(--radius);
}

.ui-preview > iframe,
.ui-preview > img,
.ui-preview > video {
  display: block;
  width: 100%;
  height: 100%;
  border: 0;
}

/* A browser paints an iframe opaque when its color scheme differs from the page inside it.
   Output pages use the default scheme, so the frame must too, or dark mode hides the transparency. */
.ui-preview > iframe {
  color-scheme: normal;
}

.ui-checker {
  background-color: var(--hatch-a);
  background-image: conic-gradient(var(--hatch-b) 0 25%, transparent 0 50%, var(--hatch-b) 0 75%, transparent 0);
  background-size: 16px 16px;
}

.ui-color-swatch {
  display: inline-block;
  flex: none;
  width: 0.9rem;
  height: 0.9rem;
  vertical-align: middle;
  background: var(--swatch, transparent);
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
}

/* ---------- State rail (last, so it wins over panel, card, and tile borders) ---------- */

.ui-rail {
  border-left: var(--rail) solid var(--state, var(--border));
}
```

## Appendix B. contrast-audit.js

Run this in the browser console on every page you build, or call it from a browser test. It returns the text elements that miss 4.5:1 (3:1 for large text) against the color they actually sit on. It composites stacked translucent tints and checks a progress label against its fill. An empty array is a pass. Switch the OS or browser to dark mode and run it again.

It does not check text on images or gradients, `::placeholder` text, text that only appears on hover or focus, or disabled controls (WCAG exempts them). The tokens cover placeholders and hover states; if you add new colors, check those by hand.

<!-- file: contrast-audit.js -->
```js
// Contrast audit for a page built with the Laggish design guide. Paste into the browser console, or run it from a test.
// It checks every visible element that owns text against the background it actually sits on,
// including stacked translucent tints and the fill under a progress-bar label.
// It returns the failures. An empty array is a pass. Run it in light and in dark mode.
(() => {
  const canvas = document.createElement("canvas")
  canvas.width = 1
  canvas.height = 1
  const context = canvas.getContext("2d", { willReadFrequently: true })
  function parse(color) {
    let match = color.match(/^rgba?\(([^)]+)\)$/)
    if (match) {
      const p = match[1].split(/[\s,/]+/).filter(Boolean).map(Number)
      return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1]
    }
    match = color.match(/^color\(srgb ([^)]+)\)$/)
    if (match) {
      const p = match[1].split(/[\s/]+/).filter(Boolean).map(Number)
      return [p[0] * 255, p[1] * 255, p[2] * 255, p.length > 3 ? p[3] : 1]
    }
    // Any other format (oklab, oklch, lab): let the canvas convert it to sRGB.
    context.clearRect(0, 0, 1, 1)
    context.fillStyle = color
    context.fillRect(0, 0, 1, 1)
    const [r, g, b, a] = context.getImageData(0, 0, 1, 1).data
    return [r, g, b, a / 255]
  }
  const over = (top, bottom) => {
    const a = top[3]
    return [top[0] * a + bottom[0] * (1 - a), top[1] * a + bottom[1] * (1 - a), top[2] * a + bottom[2] * (1 - a), 1]
  }
  const luminance = (c) => {
    const f = (v) => {
      v /= 255
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2])
  }
  const ratio = (a, b) => {
    const x = luminance(a)
    const y = luminance(b)
    return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05)
  }
  function backgroundOf(element) {
    const layers = []
    let node = element
    while (node && node.nodeType === 1) {
      const c = parse(getComputedStyle(node).backgroundColor)
      if (c && c[3] > 0) {
        layers.push(c)
        if (c[3] >= 1) break
      }
      node = node.parentElement
    }
    let base = layers.length && layers[layers.length - 1][3] >= 1
      ? layers.pop()
      : parse(getComputedStyle(document.body).backgroundColor)
    for (let i = layers.length - 1; i >= 0; i--) base = over(layers[i], base)
    return base
  }

  // Stop color fades so every element reports its final color.
  const freeze = document.createElement("style")
  freeze.textContent = "*, *::before, *::after { transition: none !important; }"
  document.head.appendChild(freeze)
  document.body.getBoundingClientRect()

  const failures = []
  for (const element of document.querySelectorAll("body *")) {
    if (element.closest("dialog:not([open]), script, style, :disabled, .ui-log-line--dim")) continue
    const ownsText = [...element.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim())
    if (!ownsText) continue
    const box = element.getBoundingClientRect()
    if (box.width === 0 || box.height === 0) continue
    const style = getComputedStyle(element)
    if (style.visibility === "hidden") continue

    const background = backgroundOf(element)
    // SVG text paints with fill, not color.
    const fg = parse(element instanceof SVGElement ? style.fill : style.color)
    const text = fg[3] < 1 ? over(fg, background) : fg
    let worst = ratio(text, background)
    let where = "background"
    // A progress label has two copies: one over the track, one clipped to the fill.
    // A single label (no on-fill copy) must pass on both.
    if (element.classList.contains("ui-progress-label")) {
      const bar = element.parentElement
      const fill = bar.querySelector(".ui-progress-fill")
      const hasOnFillCopy = bar.querySelector(".ui-progress-label--on-fill") !== null
      const isOnFillCopy = element.classList.contains("ui-progress-label--on-fill")
      const fillColor = over(parse(getComputedStyle(fill).backgroundColor), background)
      if (isOnFillCopy) {
        worst = ratio(text, fillColor)
        where = "progress fill"
      } else if (!hasOnFillCopy) {
        const onFill = ratio(text, fillColor)
        if (onFill < worst) {
          worst = onFill
          where = "progress fill"
        }
      }
    }
    const size = parseFloat(style.fontSize)
    const weight = parseInt(style.fontWeight, 10)
    const isLarge = size >= 24 || (size >= 18.66 && weight >= 700)
    const needed = isLarge ? 3 : 4.5
    if (worst < needed) {
      failures.push({
        text: element.textContent.trim().slice(0, 40),
        className: String(element.className.baseVal ?? element.className).slice(0, 60),
        ratio: Number(worst.toFixed(2)),
        needed,
        where,
      })
    }
  }
  freeze.remove()
  return failures
})()
```
