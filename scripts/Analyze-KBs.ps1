<#
.SYNOPSIS
    Structural analysis of the exported KB articles to inform a standard template.
    Read-only; prints a report and writes analysis.json.
#>
[CmdletBinding()]
param(
    [string]$ExportDir = (Join-Path $PSScriptRoot 'export')
)
$ErrorActionPreference = 'Stop'

$index = Get-Content (Join-Path $ExportDir 'index.json') -Raw | ConvertFrom-Json
$report = [System.Collections.Generic.List[object]]::new()

# Section-label words we look for in headings / bold leading text.
$labelPatterns = 'Overview','Summary','Purpose','Issue','Problem','Symptom','Cause',
    'Resolution','Solution','Steps','Procedure','Instructions','Prerequisite',
    'Requirement','Note','Warning','Result','Verification','Reference','Related',
    'Background','Scope','Audience','Contact','Escalation','FAQ','Troubleshoot'

foreach ($a in $index) {
    $html = Get-Content (Join-Path $ExportDir $a.html_file) -Raw -ErrorAction SilentlyContinue
    if ($null -eq $html) { $html = '' }
    $text = ($html -replace '<[^>]+>', ' ') -replace '&nbsp;', ' ' -replace '\s+', ' '

    $rec = [ordered]@{
        article_id  = $a.article_id
        title       = $a.title
        folder_path = $a.folder_path
        word_count  = ($text -split '\s+' | Where-Object { $_ }).Count
        h1 = ([regex]::Matches($html, '<h1', 'IgnoreCase')).Count
        h2 = ([regex]::Matches($html, '<h2', 'IgnoreCase')).Count
        h3 = ([regex]::Matches($html, '<h3', 'IgnoreCase')).Count
        h4 = ([regex]::Matches($html, '<h4', 'IgnoreCase')).Count
        ul = ([regex]::Matches($html, '<ul', 'IgnoreCase')).Count
        ol = ([regex]::Matches($html, '<ol', 'IgnoreCase')).Count
        img = ([regex]::Matches($html, '<img', 'IgnoreCase')).Count
        table = ([regex]::Matches($html, '<table', 'IgnoreCase')).Count
        link = ([regex]::Matches($html, '<a ', 'IgnoreCase')).Count
        has_keywords = [bool]$a.keywords
        has_tags = (@($a.tags).Count -gt 0)
        has_review_date = [bool]$a.review_date
        attachment_count = $a.attachment_count
    }

    # Detect which section labels appear (in headings or bold/start-of-line).
    $found = @()
    foreach ($p in $labelPatterns) {
        if ($html -match "(?i)(<(h[1-6]|strong|b)[^>]*>\s*$p|^\s*$p\s*:)") { $found += $p }
    }
    $rec.labels = $found -join ','
    $report.Add($rec)
}

# --- Aggregate report ----------------------------------------------------
$total = $report.Count
function Pct($n) { "{0,3} ({1,3:N0}%)" -f $n, (100*$n/$total) }

Write-Host "=== KB STRUCTURAL ANALYSIS ($total articles) ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Word count: min=$(($report.word_count|Measure-Object -Minimum).Minimum) max=$(($report.word_count|Measure-Object -Maximum).Maximum) avg=$([int](($report.word_count|Measure-Object -Average).Average)) median=$(($report.word_count|Sort-Object)[[int]($total/2)])"
Write-Host ""
Write-Host "Elements present in N articles:"
Write-Host "  Has any heading (h1-h4): $(Pct (@($report|?{$_.h1+$_.h2+$_.h3+$_.h4 -gt 0}).Count))"
Write-Host "  Uses H1:                 $(Pct (@($report|?{$_.h1 -gt 0}).Count))"
Write-Host "  Uses H2:                 $(Pct (@($report|?{$_.h2 -gt 0}).Count))"
Write-Host "  Uses H3:                 $(Pct (@($report|?{$_.h3 -gt 0}).Count))"
Write-Host "  Ordered list (steps):    $(Pct (@($report|?{$_.ol -gt 0}).Count))"
Write-Host "  Unordered list:          $(Pct (@($report|?{$_.ul -gt 0}).Count))"
Write-Host "  Images:                  $(Pct (@($report|?{$_.img -gt 0}).Count))"
Write-Host "  Tables:                  $(Pct (@($report|?{$_.table -gt 0}).Count))"
Write-Host "  Links:                   $(Pct (@($report|?{$_.link -gt 0}).Count))"
Write-Host "  Keywords set:            $(Pct (@($report|?{$_.has_keywords}).Count))"
Write-Host "  Tags set:                $(Pct (@($report|?{$_.has_tags}).Count))"
Write-Host "  Review date set:         $(Pct (@($report|?{$_.has_review_date}).Count))"
Write-Host ""
Write-Host "Most common section labels found:"
$labelCounts = @{}
foreach ($r in $report) { foreach ($l in ($r.labels -split ',' | Where-Object { $_ })) { $labelCounts[$l] = ($labelCounts[$l] ?? 0) + 1 } }
$labelCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 15 | ForEach-Object {
    Write-Host ("  {0,-15} {1}" -f $_.Key, (Pct $_.Value))
}
Write-Host ""
Write-Host "Articles with NO heading at all: $(Pct (@($report|?{$_.h1+$_.h2+$_.h3+$_.h4 -eq 0}).Count))"
Write-Host "Very short (<40 words):          $(Pct (@($report|?{$_.word_count -lt 40}).Count))"

$report | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $ExportDir 'analysis.json') -Encoding UTF8
Write-Host ""
Write-Host "Per-article detail written to analysis.json" -ForegroundColor Green
