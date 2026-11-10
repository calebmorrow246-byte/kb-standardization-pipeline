<#
.SYNOPSIS
    Ports the KB export from Pull-FreshServiceKBs.ps1 (categories.json, folders.json,
    index.json + articles/*.html) into a different Freshservice tenant (the LF-Triage
    sandbox), as-is — no content rewriting, just a straight structural copy.

.DESCRIPTION
    Categories: reused by exact name match if the sandbox already has one, else created.
    Folders: reused by exact name match within the resolved sandbox category (handles
    both pre-existing sandbox folders like "Drafts"/"Finance policies", and safe re-runs
    of this script), else created — preserving parent/child nesting (via folders.json's
    parent_id chain), visibility, and workspace_ids (required by Freshservice when
    visibility scopes a folder to specific workspaces, e.g. visibility 7).
    Articles: reused (skipped) if a sandbox article with the same title already exists
    in the resolved target folder (checked once per folder, cached) — else created,
    title/description/status/keywords/tags/review_date carried over as-is. Safe to
    re-run after a partial failure.

    Freshservice's Default Category cannot have folders created under it via the API
    ("Default category id is not allowed") — any folder targeting it is skipped unless
    an exact-name match already exists there to reuse.

    Known limitation: article bodies may contain inline <img> tags pointing at the
    source tenant's own signed attachment URLs (https://attachment.freshservice.com/...).
    Those tokens are tenant-scoped and will not resolve from the sandbox — images will
    show broken. Text content is unaffected. Re-uploading attachments cross-tenant is
    out of scope here.

    Sandbox credential: Windows Credential Manager target "Full Fresh Sandbox API"
    (admin-level key — the app's own scoped key is read-only on Solutions).

.PARAMETER ExportDir
    Directory produced by Pull-FreshServiceKBs.ps1 (must contain categories.json,
    folders.json, index.json, articles/).
.PARAMETER SandboxDomain
    Target Freshservice domain, host only.
.PARAMETER DryRun
    Show the create plan (categories/folders/article counts) without writing anything.
.EXAMPLE
    .\Port-KBsToSandbox.ps1 -DryRun
    .\Port-KBsToSandbox.ps1
#>
[CmdletBinding()]
param(
    [string]$ExportDir = (Join-Path $PSScriptRoot 'export-sandbox-port'),
    [string]$SandboxDomain = 'example-sandbox.freshservice.com',
    [string]$SandboxCredTarget = 'Full Fresh Sandbox API',
    [int]$ThrottleMs = 300,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

Import-Module CredentialManager
$sbCred = Get-StoredCredential -Target $SandboxCredTarget
if (-not $sbCred) { throw "No Credential Manager entry named '$SandboxCredTarget'." }
$sbKey = $sbCred.GetNetworkCredential().Password
$base = "https://$SandboxDomain/api/v2"
$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($sbKey):X"))
$headers = @{ Authorization = "Basic $basic" }

function Invoke-WithRetry([scriptblock]$Action) {
    while ($true) {
        try { return & $Action }
        catch {
            $resp = $null
            try { $resp = $_.Exception.Response } catch {}
            $code = $null
            if ($resp) { try { $code = $resp.StatusCode.value__ } catch {} }
            if ($code -eq 429) {
                $retry = 30; try { $retry = [int]$resp.Headers['Retry-After'] } catch {}
                Write-Warning "429 rate limited; waiting $retry s"; Start-Sleep -Seconds $retry; continue
            }
            throw
        }
    }
}

$prodCategories = Get-Content (Join-Path $ExportDir 'categories.json') -Raw | ConvertFrom-Json
$prodFolders    = Get-Content (Join-Path $ExportDir 'folders.json') -Raw | ConvertFrom-Json
$index          = Get-Content (Join-Path $ExportDir 'index.json') -Raw | ConvertFrom-Json

Write-Host ("Plan: {0} categories, {1} folders, {2} articles{3}" -f `
    $prodCategories.Count, $prodFolders.Count, $index.Count, $(if ($DryRun) { ' [DRY RUN]' } else { '' })) -ForegroundColor Cyan

if ($DryRun) {
    $prodCategories | ForEach-Object { Write-Host ("  category: {0}" -f $_.name) }
    $prodFolders | ForEach-Object { Write-Host ("  folder: {0} (category {1}, parent {2}, visibility {3})" -f $_.name, $_.category_id, $_.parent_id, $_.visibility) }
    Write-Host ("  {0} articles across those folders" -f $index.Count)
    exit 0
}

# --- 1. Categories: reuse exact name match, else create ---
$sbCategories = (Invoke-RestMethod -Uri "$base/solutions/categories" -Headers $headers -Method Get).categories
$catMap = @{}  # prod category_id -> sandbox category_id
foreach ($pc in $prodCategories) {
    $existing = $sbCategories | Where-Object { $_.name -eq $pc.name } | Select-Object -First 1
    if ($existing) {
        $catMap[$pc.id] = $existing.id
        Write-Host ("Category '{0}': reusing existing sandbox category (id {1})" -f $pc.name, $existing.id) -ForegroundColor DarkGray
    } else {
        $body = @{ name = $pc.name; description = $pc.description } | ConvertTo-Json
        $resp = Invoke-WithRetry { Invoke-RestMethod -Uri "$base/solutions/categories" -Headers $headers -Method Post -Body $body -ContentType 'application/json' }
        $catMap[$pc.id] = $resp.category.id
        Write-Host ("Category '{0}': created (id {1})" -f $pc.name, $resp.category.id) -ForegroundColor Green
        Start-Sleep -Milliseconds $ThrottleMs
    }
}

# --- 2. Folders: reuse by exact name within resolved category/parent, else create,
#        in parent-first order (folders.json is already ordered that way).
#        NOTE: top-level folders live under ?category_id=, but SUBfolders only show up
#        under ?parent_id= - querying by category_id alone silently misses them, which
#        previously caused re-creation attempts (409 Conflict) against subfolders a prior
#        partial run had already created. Cache separately per (category, parent). ---
$sbFoldersByScope = @{}  # "$sbCatId|$sbParentId" -> folders list (cached, fetched lazily)
function Get-SandboxChildFolders($sbCatId, $sbParentId) {
    $key = "$sbCatId|$sbParentId"
    if (-not $sbFoldersByScope.ContainsKey($key)) {
        $uri = if ($sbParentId) { "$base/solutions/folders?parent_id=$sbParentId" } else { "$base/solutions/folders?category_id=$sbCatId" }
        $sbFoldersByScope[$key] = @((Invoke-WithRetry { Invoke-RestMethod -Uri $uri -Headers $headers -Method Get }).folders)
    }
    return $sbFoldersByScope[$key]
}

$folderMap = @{}  # prod folder_id -> sandbox folder_id
$folderFail = 0
foreach ($pf in $prodFolders) {
    $sbCatId = $catMap[[int64]$pf.category_id]
    $sbParentId = $null
    if ($pf.parent_id) {
        $sbParentId = $folderMap[[int64]$pf.parent_id]
        if (-not $sbParentId) {
            Write-Host ("  SKIP folder '{0}': parent not yet created (id {1})" -f $pf.name, $pf.parent_id) -ForegroundColor Red
            $folderFail++
            continue
        }
    }

    # Reuse an existing sandbox folder with the same name in the same category+parent.
    $existing = Get-SandboxChildFolders $sbCatId $sbParentId | Where-Object { $_.name -eq $pf.name } | Select-Object -First 1
    if ($existing) {
        $folderMap[[int64]$pf.id] = $existing.id
        Write-Host ("Folder '{0}': reusing existing sandbox folder (id {1})" -f $pf.name, $existing.id) -ForegroundColor DarkGray
        continue
    }

    $body = @{ name = $pf.name; category_id = $sbCatId; visibility = $pf.visibility }
    if ($pf.description) { $body.description = $pf.description }
    if ($sbParentId) { $body.parent_id = $sbParentId }
    if ($pf.workspace_ids -and @($pf.workspace_ids).Count) { $body.workspace_ids = @($pf.workspace_ids) }
    try {
        $resp = Invoke-WithRetry { Invoke-RestMethod -Uri "$base/solutions/folders" -Headers $headers -Method Post -Body ($body | ConvertTo-Json) -ContentType 'application/json' }
        $folderMap[[int64]$pf.id] = $resp.folder.id
        $scopeKey = "$sbCatId|$sbParentId"
        if ($sbFoldersByScope.ContainsKey($scopeKey)) { $sbFoldersByScope[$scopeKey] += $resp.folder }
        Write-Host ("Folder '{0}': created (id {1})" -f $pf.name, $resp.folder.id) -ForegroundColor Green
    } catch {
        $code = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { 'non-HTTP' }
        Write-Host ("  FAILED folder '{0}' [{1}]: {2}" -f $pf.name, $code, $_.Exception.Message) -ForegroundColor Red
        $folderFail++
    }
    Start-Sleep -Milliseconds $ThrottleMs
}

# --- 3. Articles: skip if a same-titled article already exists in the target folder ---
# NOTE: the list endpoint is paginated (100/page here) - a single unpaginated GET silently
# truncates at page 1, which previously caused mass duplicate creation on any folder that
# already had more articles than one page. Always page through fully.
$sbArticleTitlesByFolder = @{}  # sandbox folder_id -> set of existing titles (cached, fetched lazily)
function Get-SandboxArticleTitlesInFolder($sbFolderId) {
    if (-not $sbArticleTitlesByFolder.ContainsKey($sbFolderId)) {
        $all = @(); $page = 1
        while ($true) {
            $batch = (Invoke-WithRetry { Invoke-RestMethod -Uri "$base/solutions/articles?folder_id=$sbFolderId&page=$page&per_page=100" -Headers $headers -Method Get }).articles
            if (-not $batch -or $batch.Count -eq 0) { break }
            $all += $batch
            if ($batch.Count -lt 100) { break }
            $page++
        }
        # Built via explicit .Add() in a loop, not the array-taking constructor - that
        # constructor previously produced an object PowerShell treated as fixed-size
        # (".Add" failed with "Collection was of a fixed size") for at least one real
        # folder here; this form is unambiguous.
        $titleSet = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($art in $all) { $titleSet.Add($art.title) | Out-Null }
        $sbArticleTitlesByFolder[$sbFolderId] = $titleSet
    }
    # The leading comma is required: `return $collection` enumerates the collection onto the
    # output pipeline rather than returning the object itself. A non-empty HashSet then arrives
    # at the caller as a plain array (mostly harmless here since arrays also support .Contains),
    # but an EMPTY HashSet enumerates to zero pipeline objects, which the caller receives as
    # $null - crashing the very next .Contains() call. The comma wraps it so exactly one object
    # (the HashSet itself, whatever its count) is returned intact.
    return ,$sbArticleTitlesByFolder[$sbFolderId]
}

$ok = 0; $fail = 0; $skipped = 0
foreach ($a in $index) {
    $sbFolderId = $folderMap[[int64]$a.folder_id]
    if (-not $sbFolderId) {
        Write-Host ("  SKIP article '{0}': target folder was never created" -f $a.title) -ForegroundColor Red
        $fail++
        continue
    }

    $existingTitles = Get-SandboxArticleTitlesInFolder $sbFolderId
    if ($existingTitles.Contains($a.title)) {
        $skipped++
        continue
    }

    # Get-Content -Raw returns $null (not "") for a genuinely empty file - a handful of source
    # articles are link-out-only entries (empty body, real content lives at an external url).
    # The API rejects a null description outright, so fall back to a plain link when present.
    $desc = Get-Content (Join-Path $ExportDir $a.html_file) -Raw
    if (-not $desc) {
        $desc = if ($a.url) { "<p>See: <a href=`"$($a.url)`">$($a.url)</a></p>" } else { "" }
    }
    $body = @{
        title       = $a.title
        description = $desc
        folder_id   = $sbFolderId
        status      = $a.status
        keywords    = @($a.keywords)
        tags        = @($a.tags)
    }
    if ($a.review_date) { $body.review_date = $a.review_date }

    try {
        $resp = Invoke-WithRetry { Invoke-RestMethod -Uri "$base/solutions/articles" -Headers $headers -Method Post -Body ($body | ConvertTo-Json -Depth 5) -ContentType 'application/json; charset=utf-8' }
        Write-Host ("  [{0}] {1}" -f $resp.article.id, $a.title) -ForegroundColor Green
        $ok++
        # Bookkeeping only - must never turn a successful creation into a reported failure.
        try { $existingTitles.Add($a.title) | Out-Null } catch { Write-Warning "Post-create bookkeeping failed for '$($a.title)' (article was still created OK): $_" }
    } catch {
        $code = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { 'non-HTTP' }
        Write-Host ("  FAILED '{0}' [{1}]: {2}" -f $a.title, $code, $_.Exception.Message) -ForegroundColor Red
        $fail++
    }
    Start-Sleep -Milliseconds $ThrottleMs
}

Write-Host ""
Write-Host ("Done. categories: {0} mapped. folders: {1} mapped, {2} failed. articles: {3} created, {4} already existed (skipped), {5} failed." -f `
    $catMap.Count, $folderMap.Count, $folderFail, $ok, $skipped, $fail) -ForegroundColor Cyan
