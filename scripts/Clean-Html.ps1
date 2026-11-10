<#
.SYNOPSIS
    Mechanical HTML sanitizer + image-extraction pass for the exported KB articles.

.DESCRIPTION
    For every article in export\index.json:
      - Extracts each <img> and replaces it with an [[IMG:n]] placeholder, storing the
        real src/alt/title in a sidecar so the conversion step never touches JWT tokens.
      - Strips style/class attributes and Word/MSO cruft, unwraps span/font, removes
        empty <p>&nbsp;</p>/<p><br></p> spacers, collapses runaway <br>.
      - Flags broken image refs (src not http) and near-empty bodies.
    Writes:
      cleaned\<stem>.html          sanitized fragment with [[IMG:n]] placeholders
      cleaned\<stem>.images.json   [ { n, src, alt, title, broken } ]
      cleaned\clean-report.json    per-article flags (broken images, empty, img count)
    Read-only w.r.t. the export; only writes under cleaned\.
#>
[CmdletBinding()]
param(
    [string]$ExportDir  = (Join-Path $PSScriptRoot 'export'),
    [string]$CleanedDir = (Join-Path $PSScriptRoot 'cleaned')
)
$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force -Path $CleanedDir | Out-Null
$index = Get-Content (Join-Path $ExportDir 'index.json') -Raw | ConvertFrom-Json
$report = [System.Collections.Generic.List[object]]::new()

function Clean-Fragment {
    param([string]$html)
    if ($null -eq $html) { return '' }

    # Word conditional comments and namespaced tags.
    $html = [regex]::Replace($html, '(?s)<!--\[if.*?<!\[endif\]-->', '')
    $html = [regex]::Replace($html, '(?s)<!--.*?-->', '')
    $html = [regex]::Replace($html, '</?(o:p|w:[^>]*|m:[^>]*|xml)[^>]*>', '', 'IgnoreCase')

    # Strip presentational / identifier attributes (single or double quoted).
    $attrs = 'style|class|lang|align|width|height|valign|border|cellpadding|cellspacing|id|title|rel|type|dir|role|data-[\w-]+'
    $html = [regex]::Replace($html, "\s+($attrs)\s*=\s*`"(?:[^`"]*)`"", '', 'IgnoreCase')
    $html = [regex]::Replace($html, "\s+($attrs)\s*=\s*'(?:[^']*)'", '', 'IgnoreCase')

    # Unwrap span / font / div (keep inner content; div->nothing leaves block flow intact).
    $html = [regex]::Replace($html, '</?(span|font|div)[^>]*>', '', 'IgnoreCase')

    # Remove empty spacer paragraphs.
    $html = [regex]::Replace($html, '(?is)<p>\s*(&nbsp;|\s|<br\s*/?>)*\s*</p>', '', 'IgnoreCase')

    # Collapse 3+ consecutive <br> down to a paragraph break's worth (2).
    $html = [regex]::Replace($html, '(?:\s*<br\s*/?>\s*){3,}', '<br><br>', 'IgnoreCase')

    # Tidy whitespace.
    $html = [regex]::Replace($html, '[ \t]{2,}', ' ')
    $html = [regex]::Replace($html, '(\r?\n){3,}', "`n`n")
    return $html.Trim()
}

foreach ($a in $index) {
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($a.html_file)
    $raw  = Get-Content (Join-Path $ExportDir $a.html_file) -Raw -ErrorAction SilentlyContinue
    if ($null -eq $raw) { $raw = '' }

    # --- Extract images, replace with placeholders ---
    $images = [System.Collections.Generic.List[object]]::new()
    $n = 0
    $withPlaceholders = [regex]::Replace($raw, '(?is)<img\b[^>]*>', {
        param($m)
        $tag = $m.Value
        $src = ([regex]::Match($tag, '(?is)\bsrc\s*=\s*"([^"]*)"')).Groups[1].Value
        if (-not $src) { $src = ([regex]::Match($tag, "(?is)\bsrc\s*=\s*'([^']*)'")).Groups[1].Value }
        $alt = ([regex]::Match($tag, '(?is)\balt\s*=\s*"([^"]*)"')).Groups[1].Value
        $title = ([regex]::Match($tag, '(?is)\btitle\s*=\s*"([^"]*)"')).Groups[1].Value
        $broken = ($src -notmatch '^https?://')
        $script:n++
        $images.Add([ordered]@{ n = $script:n; src = $src; alt = $alt; title = $title; broken = $broken })
        "[[IMG:$($script:n)]]"
    })

    $clean = Clean-Fragment $withPlaceholders

    # Plain-text length (placeholders & tags removed) to detect near-empty bodies.
    $textLen = (($clean -replace '\[\[IMG:\d+\]\]',' ' -replace '<[^>]+>',' ' -replace '&nbsp;',' ' -replace '\s+',' ').Trim()).Length

    Set-Content -Path (Join-Path $CleanedDir "$stem.html") -Value $clean -Encoding UTF8
    $images | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $CleanedDir "$stem.images.json") -Encoding UTF8

    $report.Add([ordered]@{
        stem        = $stem
        article_id  = $a.article_id
        title       = $a.title
        folder_path = $a.folder_path
        img_count   = $images.Count
        broken_imgs = @($images | Where-Object { $_.broken }).Count
        text_len    = $textLen
        near_empty  = ($textLen -lt 40)
    })
}

$report | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $CleanedDir 'clean-report.json') -Encoding UTF8

$tot = $report.Count
Write-Host "Cleaned $tot articles -> $CleanedDir" -ForegroundColor Green
Write-Host ("  total images: {0}" -f (($report.img_count | Measure-Object -Sum).Sum))
Write-Host ("  articles w/ broken img refs: {0}" -f (@($report | Where-Object { $_.broken_imgs -gt 0 }).Count))
Write-Host ("  near-empty articles (<40 chars): {0}" -f (@($report | Where-Object { $_.near_empty }).Count))
