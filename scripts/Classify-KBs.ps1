<#
.SYNOPSIS
    Heuristic archetype pre-classifier. Produces a draft manifest the AI conversion
    step will confirm/refine. Read-only except for writing manifest-draft.json.

.OUTPUT
    review\manifest-draft.json : one row per article with:
      stem, article_id, title, current_folder, archetype_guess, archetype_signals,
      img_count, broken_imgs, near_empty, status, has_keywords, has_tags, has_review_date
#>
[CmdletBinding()]
param(
    [string]$ExportDir  = (Join-Path $PSScriptRoot 'export'),
    [string]$CleanedDir = (Join-Path $PSScriptRoot 'cleaned'),
    [string]$ReviewDir  = (Join-Path $PSScriptRoot 'review')
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $ReviewDir | Out-Null

$index = Get-Content (Join-Path $ExportDir 'index.json') -Raw | ConvertFrom-Json
$cleanReport = Get-Content (Join-Path $CleanedDir 'clean-report.json') -Raw | ConvertFrom-Json
$cleanByStem = @{}; foreach ($c in $cleanReport) { $cleanByStem[$c.stem] = $c }

# Classify one article. Returns @{ archetype; signals }.
function Get-Archetype {
    param($title, $body, $folderPath)
    $t = $title; $b = $body; $f = $folderPath
    $sig = [System.Collections.Generic.List[string]]::new()

    # --- Service Overview ---
    if ($b -match '(?i)escalation path' -and $b -match '(?i)(stakeholder|service owner|tier 1)') {
        $sig.Add('escalation+stakeholders'); return @{ archetype='service-overview'; signals=($sig -join ',') }
    }

    # --- Policy ---
    if ($t -match '(?i)\bpolicy\b' -or
        ($b -match '(?i)\b\d\.0\s+(overview|purpose|scope)\b') -or
        ($b -match '(?i)\bpurpose\b' -and $b -match '(?i)\bscope\b' -and $b -match '(?i)(enforcement|compliance|revision history)') -or
        $f -match '(?i)Polic') {
        $sig.Add('policy-sections'); return @{ archetype='policy'; signals=($sig -join ',') }
    }

    # --- Reference / Catalog ---
    if (($b -match '(?i)<strong>\s*Owner\s*:' -and $b -match '(?i)(IT Admin|Onboarding|Offboarding)') -or
        $f -match '(?i)App Articles|Approved|Denied|Ignored|Review' -or
        ($b -match '(?i)mailto:' -and $b.Length -lt 600)) {
        $sig.Add('field-list/catalog'); return @{ archetype='reference'; signals=($sig -join ',') }
    }

    # --- Operational Procedure ---
    if ($f -match '(?i)Infrastructure|Linux|Server|Conference' -or
        $b -match '(?i)(prerequisite|information needed|provisioning|configure the|naming convention)') {
        $sig.Add('infra/procedure'); return @{ archetype='procedure'; signals=($sig -join ',') }
    }

    # --- Troubleshooting ---
    if ($t -match '(?i)(not working|error|issue|fix|fails?|won''t|can''t|doesn''t|unable|slow|lag|blocked)' -or
        $t -match '(?i)error code' -or
        $b -match '(?i)<(strong|b)>\s*(symptom|cause|problem|resolution)\b' -or
        $b -match '(?i)error code\s*[:#]') {
        $sig.Add('symptom/error'); return @{ archetype='troubleshooting'; signals=($sig -join ',') }
    }

    # --- How-To (default for step content) ---
    if ($t -match '(?i)^how\s*to\b' -or $b -match '(?i)<ol' -or $b -match '(?i)\bstep\s*\d') {
        $sig.Add('how-to/steps'); return @{ archetype='how-to'; signals=($sig -join ',') }
    }

    $sig.Add('default'); return @{ archetype='how-to'; signals=($sig -join ',') }
}

$manifest = [System.Collections.Generic.List[object]]::new()
foreach ($a in $index) {
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($a.html_file)
    $body = Get-Content (Join-Path $CleanedDir "$stem.html") -Raw -ErrorAction SilentlyContinue
    if ($null -eq $body) { $body = '' }
    $cls = Get-Archetype -title $a.title -body $body -folderPath $a.folder_path
    $cr = $cleanByStem[$stem]

    $manifest.Add([ordered]@{
        stem             = $stem
        article_id       = $a.article_id
        title            = $a.title
        current_folder   = $a.folder_path
        archetype_guess  = $cls.archetype
        archetype_signals= $cls.signals
        img_count        = $cr.img_count
        broken_imgs      = $cr.broken_imgs
        near_empty       = $cr.near_empty
        status           = $a.status        # 1=draft, 2=published
        is_retired       = ($a.folder_path -match '(?i)Retired')
        has_keywords     = [bool]$a.keywords
        has_tags         = (@($a.tags).Count -gt 0)
        has_review_date  = [bool]$a.review_date
    })
}

$manifest | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $ReviewDir 'manifest-draft.json') -Encoding UTF8

Write-Host "Draft manifest -> $ReviewDir\manifest-draft.json" -ForegroundColor Green
Write-Host "Archetype distribution (heuristic):"
$manifest | Group-Object archetype_guess | Sort-Object Count -Descending | ForEach-Object {
    Write-Host ("  {0,-16} {1}" -f $_.Name, $_.Count)
}
