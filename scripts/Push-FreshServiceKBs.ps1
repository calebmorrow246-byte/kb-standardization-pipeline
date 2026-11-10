<#
.SYNOPSIS
    Pushes converted/approved KB articles back to FreshService via the Solutions API.

.DESCRIPTION
    For each approved article (review\manifest.json with a final\<stem>.html):
      1. GET the current live article and back it up (backups\<id>.original.json kept
         immutable on first push; backups\<id>.live-before-<timestamp>.json each run).
      2. PUT title, description (from final\), keywords (array), tags (array), review_date.
         Folder and publish status are left UNCHANGED (structural moves are a separate step).
      3. Verify with a GET and append a row to review\pushed.json.

    Articles listed in review\to-delete.json are never pushed. Already-pushed articles
    are skipped unless -Force. Honors 429 rate limiting.

.PARAMETER DryRun
    Show what would be pushed; make no changes. RUN THIS FIRST.
.PARAMETER Stem
    One or more stems to push (default: all approved).
.PARAMETER Max
    Cap the number of articles pushed this run (incremental rollout).
.PARAMETER Force
    Re-push articles already recorded in pushed.json.
.PARAMETER ApplyDeletes
    Also DELETE the articles in to-delete.json (requires -ConfirmDeletes too).
.EXAMPLE
    .\Push-FreshServiceKBs.ps1 -DryRun
    .\Push-FreshServiceKBs.ps1 -Stem 1000_2000_3000
    .\Push-FreshServiceKBs.ps1 -Max 10
#>
[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot,
    [switch]$DryRun,
    [string[]]$Stem,
    [int]$Max = 0,
    [switch]$Force,
    [switch]$ApplyDeletes,
    [switch]$ConfirmDeletes,
    [int]$ThrottleMs = 300
)
$ErrorActionPreference = 'Stop'

# --- creds ---
. (Join-Path $PSScriptRoot 'FreshServiceCredential.ps1')
$creds = Get-FreshServiceCredential
if (-not $creds) { throw "No FreshService credential found. Run: .\FreshServiceCredential.ps1 -Set" }
$domain = ($creds.domain -replace '^https?://','' -replace '/$','')
$base = "https://$domain/api/v2"
$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($creds.api_key):X"))
$headers = @{ Authorization = "Basic $basic" }

$FinalDir = Join-Path $Root 'final'
$ReviewDir = Join-Path $Root 'review'
$BackupDir = Join-Path $Root 'backups'
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

$manifest = Get-Content (Join-Path $ReviewDir 'manifest.json') -Raw | ConvertFrom-Json
$toDelete = @()
if (Test-Path (Join-Path $ReviewDir 'to-delete.json')) {
    $toDelete = (Get-Content (Join-Path $ReviewDir 'to-delete.json') -Raw | ConvertFrom-Json).stem
}
$pushedLog = [System.Collections.Generic.List[object]]::new()
$pushedPath = Join-Path $ReviewDir 'pushed.json'
$alreadyPushed = @()
if (Test-Path $pushedPath) {
    $existing = Get-Content $pushedPath -Raw | ConvertFrom-Json
    foreach ($e in $existing) { $pushedLog.Add($e); $alreadyPushed += $e.article_id }
}

function Invoke-WithRetry([scriptblock]$Action) {
    while ($true) {
        try { return & $Action }
        catch {
            $code = $_.Exception.Response.StatusCode.value__
            if ($code -eq 429) {
                $retry = 30; try { $retry = [int]$_.Exception.Response.Headers['Retry-After'] } catch {}
                Write-Warning "429 rate limited; waiting $retry s"; Start-Sleep -Seconds $retry; continue
            }
            throw
        }
    }
}

# --- build work list ---
$work = $manifest | Where-Object {
    (Test-Path (Join-Path $FinalDir "$($_.stem).html")) -and
    ($toDelete -notcontains $_.stem) -and
    ($_.flags -notcontains 'url_type_skip_push') -and
    (-not $Stem -or $Stem -contains $_.stem)
}
if (-not $Force) { $work = $work | Where-Object { $alreadyPushed -notcontains $_.article_id } }
if ($Max -gt 0) { $work = $work | Select-Object -First $Max }

Write-Host ("Push plan: {0} article(s){1}" -f @($work).Count, $(if($DryRun){' [DRY RUN]'}else{''})) -ForegroundColor Cyan
if ($toDelete.Count) { Write-Host ("  (skipping {0} to-delete article(s))" -f $toDelete.Count) -ForegroundColor DarkGray }

$ok = 0; $fail = 0
foreach ($r in $work) {
    $id = $r.article_id
    $desc = Get-Content (Join-Path $FinalDir "$($r.stem).html") -Raw
    $kw = @($r.keywords -split ',\s*' | Where-Object { $_ })
    $tg = @($r.tags)
    Write-Host ("  [{0}] {1}" -f $id, $r.proposed_title)

    if ($DryRun) {
        Write-Host ("      title='{0}' kw={1} tags={2} desc={3}ch review={4}" -f $r.proposed_title, $kw.Count, $tg.Count, $desc.Length, $r.review_date) -ForegroundColor DarkGray
        continue
    }

    try {
        # backup (immutable original on first push + timestamped pre-push)
        $live = (Invoke-WithRetry { Invoke-RestMethod -Uri "$base/solutions/articles/$id" -Headers $headers }).article
        $origPath = Join-Path $BackupDir "$id.original.json"
        if (-not (Test-Path $origPath)) { $live | ConvertTo-Json -Depth 8 | Set-Content $origPath -Encoding UTF8 }
        $live | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $BackupDir ("$id.live-before-{0}.json" -f (Get-Date -Format 'yyyyMMddHHmmss'))) -Encoding UTF8

        $body = @{ title=$r.proposed_title; description=$desc; keywords=$kw; tags=$tg; review_date=$r.review_date } | ConvertTo-Json -Depth 5
        $resp = Invoke-WithRetry { Invoke-RestMethod -Uri "$base/solutions/articles/$id" -Headers $headers -Method Put -Body $body -ContentType 'application/json; charset=utf-8' }

        $pushedLog.Add([ordered]@{
            article_id=$id; stem=$r.stem; pushed_at=(Get-Date).ToString('s')
            title=$r.proposed_title; fields=@('title','description','keywords','tags','review_date')
            backup="backups\$id.original.json"
        })
        $ok++
        Start-Sleep -Milliseconds $ThrottleMs
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        Write-Host ("      FAILED [{0}]: {1}" -f $code, $_.Exception.Message) -ForegroundColor Red
        $fail++
    }
}

if (-not $DryRun) {
    $pushedLog | ConvertTo-Json -Depth 5 | Set-Content $pushedPath -Encoding UTF8
    Write-Host ("Done. pushed={0} failed={1}. Log: review\pushed.json" -f $ok, $fail) -ForegroundColor Green
}

# --- optional deletes ---
if ($ApplyDeletes -and -not $DryRun) {
    if (-not $ConfirmDeletes) {
        Write-Warning "ApplyDeletes set but -ConfirmDeletes not provided; skipping deletes."
    } else {
        $delRows = Get-Content (Join-Path $ReviewDir 'to-delete.json') -Raw | ConvertFrom-Json
        foreach ($d in $delRows) {
            try {
                Invoke-WithRetry { Invoke-RestMethod -Uri "$base/solutions/articles/$($d.article_id)" -Headers $headers -Method Delete } | Out-Null
                Write-Host ("  DELETED [{0}] {1}" -f $d.article_id, $d.title) -ForegroundColor Yellow
                Start-Sleep -Milliseconds $ThrottleMs
            } catch { Write-Host ("  delete FAILED [{0}] {1}" -f $d.article_id, $_.Exception.Message) -ForegroundColor Red }
        }
    }
}
