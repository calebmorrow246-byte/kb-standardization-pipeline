# KB Standardization Pipeline — migrating a 326-article IT knowledge base with an AI agent

A set of PowerShell scripts plus a documented AI-agent runbook that took a real, inconsistent IT knowledge base in Freshservice and rebuilt it onto a small set of standard article templates: pulled out through the API, sanitized, classified, rewritten by Claude Code in reviewed batches, checked locally, then pushed back with backups and a dry-run mode.

**Status:** original migration complete (2026-07-30); the same tooling is the standing workflow for every new or revised article. The numbers below come from the project's own reconciliation record.

> This repository has been scrubbed of identifying information. It contains the scripts, templates and method only. No article content, backups, manifests or credentials are included.

---

## Why this exists

The knowledge base had accumulated years of articles with inconsistent structure, Word-paste HTML cruft, missing keywords and review dates, duplicates, and stale content. It was slow for technicians to maintain and poor for self-service. Fixing 326 articles by hand is weeks of repetitive editing, and doing it as a blind bulk rewrite would be unsafe: you can't tell what the AI changed or broke.

## Why it was built this way

- **Deterministic plumbing in scripts, judgment in the AI.** The scripts do everything that has a right answer (pull, sanitize, reassemble, verify, push). The AI does only the part that needs reading comprehension: choosing the right article type and rewriting the body into it.
- **No LLM API call in the code.** The rewrite step is performed by Claude Code itself, driven by a documented subagent prompt. Batches of about 14 articles each were run in waves of roughly four parallel agents. This makes the process auditable and cheap to change (edit the prompt, not a service), and it let the agent use vision to read embedded screenshots and write accurate, image-grounded step descriptions and captions for image-heavy articles.
- **Images are protected by placeholders.** `Clean-Html.ps1` replaces every `<img>` with a `[[IMG:n]]` token plus a sidecar file, so the AI never sees (or alters) tokenized image URLs. `Build-Review.ps1` restores the real sources and verifies that every placeholder came back exactly once.
- **Review before anything goes live.** Rebuilt articles are assembled into a local before/after review page. Nothing is pushed until it has been reviewed.
- **Safe push.** `Push-FreshServiceKBs.ps1` backs up the live article first (an immutable original on first push plus a timestamped snapshot every run), supports `-DryRun`, and keeps folder moves and deletes as explicit, separate steps.
- **Six archetypes, not free-form.** Every article is rewritten into one of: how-to, troubleshooting, policy, reference, procedure, service-overview. Templates and a style guide in `templates/` define allowed tags, heading levels, title conventions and the image rules, so output is consistent and lintable.
- **Secrets stay out of files.** The API key lives in Windows Credential Manager (or an environment variable); nothing sensitive is written to disk.

## What it improves

| Outcome | Result |
|---|---|
| Articles pulled | 326 |
| Converted and finalized onto templates | 324 (incl. one new article) |
| Pushed live | 307 |
| Retired (soft-deleted, restorable, with documented reasons: stale, broken attachments, duplicates) | 17 |
| Intentionally left alone | 1 (a URL-type article the API can't update) |
| Blocked | 0 |

Current article mix by archetype: how-to 134, procedure 67, troubleshooting 65, reference 51, policy 7, service-overview 3.

Beyond the one-time migration, `New-FreshServiceKBs.ps1` creates or revises single articles (including image upload) against the same templates, and re-running `Pull-FreshServiceKBs.ps1` surfaces new or changed articles that haven't been through the pipeline.

## How it works

```
Pull-FreshServiceKBs   categories → folders → articles (read-only) → raw HTML + metadata
        ↓
Clean-Html             strip Word/MSO markup; <img> → [[IMG:n]] + sidecar
        ↓
Classify-KBs           heuristic archetype guess → draft manifest
        ↓
AI rewrite (Claude Code, batches of ~14, parallel waves, vision for screenshots)
        ↓
Build-Review           restore images, verify integrity, build before/after review page
        ↓  (human review)
Push-FreshServiceKBs   backup → push body/title/keywords/tags/review date  (-DryRun supported)
```

```
scripts/
  FreshServiceCredential.ps1   store/read the API key via Windows Credential Manager
  Pull-FreshServiceKBs.ps1     read-only export of the whole KB
  Clean-Html.ps1               sanitize HTML, image placeholders
  Classify-KBs.ps1             heuristic archetype classifier
  Build-Review.ps1             reassemble, verify, build the review viewer
  Push-FreshServiceKBs.ps1     push with backups, dry-run, explicit deletes
  New-FreshServiceKBs.ps1      create/revise single articles incl. image upload
  Port-KBsToSandbox.ps1        copy articles into a sandbox tenant for testing
  Analyze-KBs.ps1              structural stats (headings/lists/tables/images/word counts)
templates/                     the six archetype templates + style-guide.md
```

Freshservice API quirks learned the hard way (worth knowing if you build on it): sub-folders come from `/solutions/folders?parent_id=` (there is no `sub_folders` endpoint); the article body field is `description`; `keywords` is an array; URL-type articles reject an HTML body update with a 400; a 403 on update means the API agent lacks folder-level manage permission.

## Stack

PowerShell 7, Freshservice REST API (Solutions), Claude Code (batch content transformation with vision), Windows Credential Manager.

## Use it

```powershell
.\scripts\FreshServiceCredential.ps1 -Set       # one-time: domain + API key
.\scripts\Pull-FreshServiceKBs.ps1               # export
.\scripts\Clean-Html.ps1                         # sanitize
.\scripts\Classify-KBs.ps1                       # draft manifest
# ... rewrite batches with your AI agent against templates/ ...
.\scripts\Build-Review.ps1                       # verify + review page
.\scripts\Push-FreshServiceKBs.ps1 -DryRun       # preview, then run without -DryRun
```

The scripts expect a working folder with `export\`, `cleaned\`, `converted\`, `final\`, `review\` and `backups\` subfolders, which they create as needed. Review the script headers for parameters.

## License

MIT — see `LICENSE`.
