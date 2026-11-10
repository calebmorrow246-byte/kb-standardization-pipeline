<#
.SYNOPSIS
    Pulls every FreshService Solutions KB article (categories -> folders -> articles)
    and saves them locally as raw HTML + a metadata JSON index.

.DESCRIPTION
    Reads credentials so nothing sensitive is written into this
    folder. Priority: environment variables, then Windows Credential Manager
    (see FreshServiceCredential.ps1 -Set to store them there).
        $env:FRESHSERVICE_DOMAIN    e.g. example.freshservice.com
        $env:FRESHSERVICE_API_KEY   your FreshService API key

    Output layout (under .\export):
        export\index.json                          full metadata for every article
        export\categories.json                     raw category list
        export\articles\<catId>_<folderId>_<artId>.html   raw HTML body per article
        export\articles\<catId>_<folderId>_<artId>.json    per-article metadata

.NOTES
    Read-only. Makes no changes in FreshService.
#>

[CmdletBinding()]
param(
    [string]$OutputDir = (Join-Path $PSScriptRoot 'export'),
    [int]$PerPage = 100,
    # Throttle between calls (ms) to stay under the per-minute rate limit.
    [int]$ThrottleMs = 200,
    # Only pull these categories (by name). Empty = all categories.
    [string[]]$CategoryFilter = @('IT Knowledge Base'),
    # Dry run: only list categories/folders and article counts. No downloads.
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# --- Credentials ---------------------------------------------------------
# Priority: env vars, then Windows Credential Manager (nothing sensitive on disk).
$domain = $env:FRESHSERVICE_DOMAIN
$apiKey = $env:FRESHSERVICE_API_KEY

if ([string]::IsNullOrWhiteSpace($domain) -or [string]::IsNullOrWhiteSpace($apiKey)) {
    . (Join-Path $PSScriptRoot 'FreshServiceCredential.ps1')
    $creds = Get-FreshServiceCredential
    if ($creds) {
        if ([string]::IsNullOrWhiteSpace($domain)) { $domain = $creds.domain }
        if ([string]::IsNullOrWhiteSpace($apiKey)) { $apiKey = $creds.api_key }
    }
}

if ([string]::IsNullOrWhiteSpace($domain) -or [string]::IsNullOrWhiteSpace($apiKey)) {
    throw "No credentials. Set `$env:FRESHSERVICE_DOMAIN/`$env:FRESHSERVICE_API_KEY or run: .\FreshServiceCredential.ps1 -Set"
}
$domain = $domain -replace '^https?://', '' -replace '/$', ''
$baseUrl = "https://$domain/api/v2"

# Basic auth: apiKey:X
$pair  = "{0}:X" -f $apiKey
$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$headers = @{ Authorization = "Basic $basic" }

# --- Helper: GET with pagination + rate-limit handling -------------------
function Invoke-FsGet {
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query = @{},
        [string]$Collection  # JSON property holding the array; $null for single object
    )

    $results = @()
    $page = 1
    while ($true) {
        $qs = @()
        foreach ($k in $Query.Keys) { $qs += "$k=$($Query[$k])" }
        if ($Collection) { $qs += "page=$page"; $qs += "per_page=$PerPage" }
        $url = "$baseUrl/$Path"
        if ($qs.Count) { $url += "?" + ($qs -join '&') }

        try {
            $resp = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
        }
        catch {
            $code = $_.Exception.Response.StatusCode.value__
            if ($code -eq 429) {
                $retry = 30
                try { $retry = [int]$_.Exception.Response.Headers['Retry-After'] } catch {}
                Write-Warning "Rate limited. Waiting $retry s..."
                Start-Sleep -Seconds $retry
                continue
            }
            throw "GET $url failed: $($_.Exception.Message)"
        }

        if (-not $Collection) { return $resp }

        $batch = $resp.$Collection
        if (-not $batch) { break }
        $results += $batch
        if ($batch.Count -lt $PerPage) { break }
        $page++
        Start-Sleep -Milliseconds $ThrottleMs
    }
    return $results
}

# Recursively gather a folder plus all of its sub-folders (flattened).
# Each item gets a 'path' showing its nesting (e.g. "Parent / Child").
function Get-FolderTree {
    param([Parameter(Mandatory)]$Folder, [string]$ParentPath = '')

    $path = if ($ParentPath) { "$ParentPath / $($Folder.name)" } else { $Folder.name }
    $Folder | Add-Member -NotePropertyName 'path' -NotePropertyValue $path -Force
    $out = @($Folder)

    # Sub-folders are listed via ?parent_id=. Only query when the folder declares it has any.
    if ($Folder.has_subfolders) {
        $subs = Invoke-FsGet -Path 'solutions/folders' -Query @{ parent_id = $Folder.id } -Collection 'folders'
        foreach ($s in $subs) {
            $out += Get-FolderTree -Folder $s -ParentPath $path
        }
    }
    Start-Sleep -Milliseconds $ThrottleMs
    return $out
}

# --- Crawl ---------------------------------------------------------------
if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $artDir = Join-Path $OutputDir 'articles'
    New-Item -ItemType Directory -Force -Path $artDir | Out-Null
}

Write-Host ("Connecting to {0}{1}" -f $baseUrl, $(if ($DryRun) { '  [DRY RUN]' } else { '' })) -ForegroundColor Cyan
Write-Host "Fetching categories..." -ForegroundColor Cyan
$categories = Invoke-FsGet -Path 'solutions/categories' -Collection 'categories'
if (-not $DryRun) {
    $categories | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $OutputDir 'categories.json') -Encoding UTF8
}
Write-Host ("  {0} categories" -f $categories.Count)

if ($CategoryFilter.Count) {
    $categories = $categories | Where-Object { $CategoryFilter -contains $_.name }
    Write-Host ("  filtered to: {0}" -f (($categories.name) -join ', ')) -ForegroundColor Yellow
}

$index = [System.Collections.Generic.List[object]]::new()
$totalArticles = 0

foreach ($cat in $categories) {
    Write-Host ("Category: {0} (id {1})" -f $cat.name, $cat.id) -ForegroundColor Cyan
    $topFolders = Invoke-FsGet -Path 'solutions/folders' -Query @{ category_id = $cat.id } -Collection 'folders'
    # Expand each top-level folder into itself + all nested sub-folders.
    $folders = @()
    foreach ($tf in $topFolders) { $folders += Get-FolderTree -Folder $tf }
    Write-Host ("  {0} folders (incl. sub-folders)" -f $folders.Count)

    foreach ($folder in $folders) {
        $articles = Invoke-FsGet -Path 'solutions/articles' -Query @{ folder_id = $folder.id } -Collection 'articles'
        Write-Host ("  Folder: {0} (id {1}) - {2} articles" -f $folder.path, $folder.id, $articles.Count)
        $totalArticles += $articles.Count

        if ($DryRun) { Start-Sleep -Milliseconds $ThrottleMs; continue }

        foreach ($artStub in $articles) {
            # Fetch full article to guarantee we get the description (HTML body).
            $full = Invoke-FsGet -Path ("solutions/articles/{0}" -f $artStub.id)
            $a = $full.article
            Start-Sleep -Milliseconds $ThrottleMs

            $stem = "{0}_{1}_{2}" -f $cat.id, $folder.id, $a.id
            $htmlPath = Join-Path $artDir "$stem.html"
            $metaPath = Join-Path $artDir "$stem.json"

            ($a.description) | Set-Content -Path $htmlPath -Encoding UTF8

            $meta = [ordered]@{
                article_id    = $a.id
                title         = $a.title
                category_id   = $cat.id
                category_name = $cat.name
                folder_id     = $folder.id
                folder_name   = $folder.name
                folder_path   = $folder.path
                status        = $a.status
                article_type  = $a.article_type
                keywords      = $a.keywords
                tags          = $a.tags
                review_date   = $a.review_date
                views         = $a.views
                thumbs_up     = $a.thumbs_up
                thumbs_down   = $a.thumbs_down
                attachment_count = @($a.attachments).Count
                attachment_urls  = $a.attachment_urls
                url           = $a.url
                created_at    = $a.created_at
                updated_at    = $a.updated_at
                html_file     = "articles/$stem.html"
            }
            $meta | ConvertTo-Json -Depth 5 | Set-Content -Path $metaPath -Encoding UTF8
            $index.Add($meta)
        }
    }
}

Write-Host ""
if ($DryRun) {
    Write-Host ("DRY RUN complete. {0} categories, {1} articles total. No files written." -f $categories.Count, $totalArticles) -ForegroundColor Green
    return
}

$index | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputDir 'index.json') -Encoding UTF8
Write-Host ("Done. {0} articles exported to {1}" -f $index.Count, $OutputDir) -ForegroundColor Green
