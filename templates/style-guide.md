# IT Knowledge Base — Style Guide

Standards every knowledge base article must follow. The templates in this folder implement these rules; this doc explains them.

## 1. Article body is an HTML fragment

FreshService stores the article body (`description` field) as an HTML fragment — **no** `<html>`, `<head>`, or `<body>` wrappers. Start directly with content. The article **title** is a separate field; do **not** repeat it as an `<h1>` inside the body (FreshService renders the title above the body).

## 2. Use semantic headings, not bold text

- Major sections → `<h2>`
- Sub-sections / phases / sub-steps → `<h3>`
- **Never** fake a heading with `<p><strong>…</strong></p>`. Real headings give a table of contents, accessibility, and consistency.
- Don't skip levels (no `<h3>` without a parent `<h2>`).

## 3. Allowed tags only

`h2 h3 p ul ol li strong em a img figure figcaption table thead tbody tr th td br hr code pre`

Everything else (`span`, `div`, `font`, `o:p`, MSO tags) is removed by `Clean-Html.ps1`.

## 4. No inline styling

- **No** `style=` attributes. No `font-family`, `margin`, `line-height`, `color`, `mso-*`.
- **No** `class=` attributes (FreshService theme controls appearance).
- Spacing comes from real block elements, never from `<p>&nbsp;</p>` or stacked `<br>`.

## 5. Steps and lists

- Sequential steps → `<ol>` (one `<li>` per step). Never hand-number ("1." "2." as text).
- Non-sequential items → `<ul>`.
- Nest sub-steps with a child `<ol>`/`<ul>` inside the parent `<li>`.

## 6. Screenshots / images

- Wrap each image in `<figure>` with a `<figcaption>` describing it.
- Every `<img>` needs meaningful, non-empty `alt` text.
- **Preserve the `src` exactly** — FreshService inline images use `https://attachment.freshservice.com/inline/attachment?token=<JWT>` tokens tied to the article. Do not alter, re-encode, or drop them.
- Broken legacy refs (e.g. `*.pngx`, `sys_attachment.do?...`) are flagged in the manifest, not silently removed.

## 7. Links

- Use descriptive link text, not bare URLs ("the Company Portal", not "click here" or `https://…`).
- Internal KB cross-links use the article's FreshService URL.

## 8. Metadata (set on the article, not in the body)

Every article should have:
- **Keywords** — salient search terms: product names, error codes, systems, synonyms.
- **Tags** — the archetype tag (`how-to`, `troubleshooting`, `policy`, `reference`, `procedure`, `service-overview`) plus topic tags (`outlook`, `email`, `linux`, …).
- **Review date** — mandatory for Policy (1 year out); default 1 year for all others.

## 9. The six templates

| Template | Use for |
|---|---|
| `how-to.html` | End-user / IT task with sequential steps. |
| `troubleshooting.html` | A problem/error and its fix. |
| `policy.html` | Formal policy/compliance document. |
| `reference.html` | Fact-sheets, catalogs, contact cards, naming conventions. |
| `procedure.html` | Detailed IT operational runbook (servers, infra). |
| `service-overview.html` | System/service hub page (owner, escalation, related KBs). Models the Cayosoft example. |

## 10. Titles

- How-To → `How to <verb> <object>` (e.g. "How to export an Outlook calendar to .ics").
- Troubleshooting → `<Product/Feature>: <symptom>` — keep error codes verbatim.
- Policy → `<Scope> Policy`.
- Reference → `<Name> — Reference` / fact-sheet name.
- Procedure → `<System> — <task>`.
- Service Overview → `<Service> — Service Overview`.
