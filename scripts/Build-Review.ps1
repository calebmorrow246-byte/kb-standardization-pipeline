<#
.SYNOPSIS
    Reassembles converted articles (restores exact image src from sidecars),
    runs integrity verification, and builds a before/after review page.

.DESCRIPTION
    Driven by review\manifest.json. For each row:
      - reads converted\<stem>.html (with [[IMG:n]] placeholders),
      - restores real <img> src values from cleaned\<stem>.images.json,
      - writes final\<stem>.html (push-ready body),
      - verifies every placeholder resolves and no non-broken source image was dropped.
    Then writes review\index.html: a self-contained before/after viewer.
.OUTPUT
    final\<stem>.html, review\index.html, review\verify-report.json
#>
[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot
)
$ErrorActionPreference = 'Stop'
$ConvertedDir = Join-Path $Root 'converted'
$FinalDir     = Join-Path $Root 'final'
$ReviewDir    = Join-Path $Root 'review'
$ArchiveDir   = Join-Path $Root 'archive\kb-standardization-326'
New-Item -ItemType Directory -Force -Path $FinalDir | Out-Null

# export\ and cleaned\ hold raw pulls / sanitized bodies + image sidecars. For
# articles from the original 326-migration these were moved to $ArchiveDir;
# for newly pulled articles they'll be fresh at root. Prefer root, fall back
# to the archive, so this script works for both old and new stems.
function Resolve-PipelineDir([string]$Name) {
    $rootPath = Join-Path $Root $Name
    if (Test-Path $rootPath) { return $rootPath }
    $archivePath = Join-Path $ArchiveDir $Name
    if (Test-Path $archivePath) { return $archivePath }
    return $rootPath
}
$ExportDir  = Resolve-PipelineDir 'export'
$CleanedDir = Resolve-PipelineDir 'cleaned'

$manifest = Get-Content (Join-Path $ReviewDir 'manifest.json') -Raw | ConvertFrom-Json
$toDeleteIds = @{}
$tdPath = Join-Path $ReviewDir 'to-delete.json'
if (Test-Path $tdPath) { foreach ($d in (Get-Content $tdPath -Raw | ConvertFrom-Json)) { $toDeleteIds["$($d.article_id)"] = $true } }
$verify   = [System.Collections.Generic.List[object]]::new()
$cards    = [System.Collections.Generic.List[string]]::new()

function To-B64([string]$s) {
    if ($null -eq $s) { $s = '' }
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s))
}
function Esc([string]$s) {
    if ($null -eq $s) { return '' }
    $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
}

foreach ($row in $manifest) {
    $stem = $row.stem
    $rawPath  = Join-Path $ExportDir   "articles\$stem.html"
    $convPath = Join-Path $ConvertedDir "$stem.html"
    $imgPath  = Join-Path $CleanedDir   "$stem.images.json"

    $raw  = (Test-Path $rawPath)  ? (Get-Content $rawPath  -Raw) : '(missing original)'
    $conv = (Test-Path $convPath) ? (Get-Content $convPath -Raw) : $null
    $imgs = (Test-Path $imgPath)  ? (Get-Content $imgPath -Raw | ConvertFrom-Json) : @()
    $imgMap = @{}; foreach ($im in $imgs) { $imgMap["$($im.n)"] = $im }

    $issues = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $conv) {
        $issues.Add('converted file missing')
        $final = '(not yet converted)'
    } else {
        # Which placeholders did the conversion use?
        $used = [regex]::Matches($conv, '\[\[IMG:(\d+)\]\]') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique
        # Restore real src for each placeholder.
        $final = [regex]::Replace($conv, '\[\[IMG:(\d+)\]\]', {
            param($m)
            $key = $m.Groups[1].Value
            if ($imgMap.ContainsKey($key)) { return $imgMap[$key].src }
            $issues.Add("placeholder IMG:$key has no source"); return $m.Value
        })
        # Did we drop any non-broken source images?
        # (Skip when the row is flagged 'content_image_dropped' — an intentional content removal.)
        foreach ($im in $imgs) {
            if (-not $im.broken -and ($used -notcontains [int]$im.n)) {
                if ($row.flags -contains 'content_image_dropped') { continue }
                $issues.Add("source image $($im.n) dropped (not broken)")
            }
        }
        # Residual placeholder?
        if ($final -match '\[\[IMG:\d+\]\]') { $issues.Add('unresolved placeholder remains') }
        Set-Content -Path (Join-Path $FinalDir "$stem.html") -Value $final -Encoding UTF8
    }

    $verify.Add([ordered]@{
        stem = $stem; article_id = $row.article_id; archetype = $row.archetype
        img_total = @($imgs).Count; img_broken = @($imgs | Where-Object { $_.broken }).Count
        issues = @($issues)
    })

    # --- Build a review card ---
    $flags = if ($row.flags) { ($row.flags -join ', ') } else { '' }
    $tags  = if ($row.tags)  { ($row.tags  -join ', ') } else { '' }
    $isRetired = ($row.flags -contains 'retired') -or $toDeleteIds.ContainsKey("$($row.article_id)")
    $retiredBanner = if ($isRetired) { "<div class='retired-banner'>&#9851; RETIRED &mdash; will be deleted (not pushed)</div>" } else { '' }
    $issueHtml = if ($issues.Count) { "<div class='issues'>&#9888; " + (Esc ($issues -join '; ')) + "</div>" } else { "<div class='ok'>&#10003; image integrity OK</div>" }
    $cards.Add(@"
<section class="card$(if($isRetired){' retired'})" data-arch="$($row.archetype)" data-retired="$(if($isRetired){'1'}else{'0'})">
  $retiredBanner
  <div class="meta">
    <span class="badge $($row.archetype)">$($row.archetype)</span>
    <h2>$(Esc $row.proposed_title)</h2>
    <table class="kv">
      <tr><th>Original title</th><td>$(Esc $row.original_title)</td></tr>
      <tr><th>Folder</th><td>$(Esc $row.current_folder) &rarr; <strong>$(Esc $row.proposed_folder)</strong></td></tr>
      <tr><th>Keywords</th><td>$(Esc $row.keywords)</td></tr>
      <tr><th>Tags</th><td>$(Esc $tags)</td></tr>
      <tr><th>Review date</th><td>$(Esc $row.review_date)</td></tr>
      <tr><th>Flags</th><td>$(Esc $flags)</td></tr>
      <tr><th>Notes</th><td>$(Esc $row.notes)</td></tr>
    </table>
    $issueHtml
  </div>
  <div class="cols">
    <div class="col"><h3>Before (original)</h3><div class="render" data-b64="$(To-B64 $raw)"></div></div>
    <div class="col"><h3>After (template)</h3><div class="render after" data-b64="$(To-B64 $final)"></div></div>
  </div>
</section>
"@)
}

$verify | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $ReviewDir 'verify-report.json') -Encoding UTF8

# --- Assemble page ---
$retiredCount = @($manifest | Where-Object { ($_.flags -contains 'retired') -or $toDeleteIds.ContainsKey("$($_.article_id)") }).Count
$activeCount  = $manifest.Count - $retiredCount
$archetypes = ($manifest.archetype | Sort-Object -Unique)
$filterBtns = "<button class='f active' data-f='all'>All ($($manifest.Count))</button>" +
    "<button class='f' data-f='active'>Active ($activeCount)</button>" +
    "<button class='f' data-f='retired'>Retired ($retiredCount)</button>" + (
    ($archetypes | ForEach-Object { $a = $_; "<button class='f' data-f='$a'>$a ($(@($manifest | Where-Object {$_.archetype -eq $a}).Count))</button>" }) -join '' )
$totalIssues = (@($verify | Where-Object { $_.issues.Count -gt 0 }).Count)

$page = @"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>KB Conversion Review</title>
<style>
  body{font-family:Segoe UI,system-ui,sans-serif;margin:0;background:#f4f5f7;color:#1a1a1a}
  header{position:sticky;top:0;background:#fff;border-bottom:1px solid #ddd;padding:12px 20px;z-index:10}
  header h1{margin:0 0 8px;font-size:18px}
  .f{border:1px solid #ccc;background:#fff;border-radius:16px;padding:4px 12px;margin-right:6px;cursor:pointer;font-size:13px}
  .f.active{background:#0b5fff;color:#fff;border-color:#0b5fff}
  .summary{font-size:13px;color:#555;margin-top:6px}
  .card{background:#fff;margin:16px 20px;border:1px solid #e1e1e1;border-radius:8px;overflow:hidden}
  .card.retired{opacity:.6;border-color:#9b1c1c}
  .retired-banner{background:#9b1c1c;color:#fff;font-size:12px;font-weight:700;padding:6px 18px;letter-spacing:.5px}
  .meta{padding:14px 18px;border-bottom:1px solid #eee}
  .meta h2{margin:6px 0 10px;font-size:17px}
  .badge{display:inline-block;font-size:11px;text-transform:uppercase;letter-spacing:.5px;padding:2px 8px;border-radius:4px;background:#eef;color:#225;font-weight:600}
  .badge.policy{background:#fde8e8;color:#9b1c1c}.badge.troubleshooting{background:#fef3cd;color:#8a6d00}
  .badge.how-to{background:#e6f4ea;color:#1e6b34}.badge.procedure{background:#e7e9fd;color:#3730a3}
  .badge.reference{background:#e0f2fe;color:#075985}.badge.service-overview{background:#f3e8ff;color:#6b21a8}
  table.kv{border-collapse:collapse;font-size:13px;width:100%;max-width:760px}
  table.kv th{text-align:left;color:#666;font-weight:600;padding:2px 10px 2px 0;vertical-align:top;white-space:nowrap;width:110px}
  table.kv td{padding:2px 0}
  .issues{margin-top:8px;color:#9b1c1c;font-size:13px;font-weight:600}
  .ok{margin-top:8px;color:#1e6b34;font-size:13px}
  .cols{display:grid;grid-template-columns:1fr 1fr;gap:0}
  .col{padding:14px 18px;overflow:auto}
  .col:first-child{border-right:1px solid #eee;background:#fafafa}
  .col h3{margin:0 0 10px;font-size:12px;text-transform:uppercase;color:#888;letter-spacing:.5px}
  .render{font-size:14px;line-height:1.5}
  .render img{max-width:100%;height:auto;border:1px solid #ddd;margin:4px 0}
  .render table{border-collapse:collapse;margin:8px 0}
  .render th,.render td{border:1px solid #ccc;padding:4px 8px;text-align:left}
  .render figure{margin:8px 0}.render figcaption{font-size:12px;color:#666;font-style:italic}
  .render.after{}
</style></head><body>
<header>
  <h1>KB Conversion Review &mdash; $($manifest.Count) article(s)</h1>
  <div>$filterBtns</div>
  <div class="summary">Image-integrity issues: <strong>$totalIssues</strong> article(s). Active: <strong>$activeCount</strong> &middot; Retired (will be deleted, not pushed): <strong>$retiredCount</strong>. Originals on the left, template-converted on the right. (Inline images may require a FreshService session to load.)</div>
</header>
<main>
$($cards -join "`n")
</main>
<script>
  function render(el){
    const b=el.getAttribute('data-b64');
    const bytes=Uint8Array.from(atob(b),c=>c.charCodeAt(0));
    el.innerHTML=new TextDecoder('utf-8').decode(bytes);
  }
  document.querySelectorAll('.render').forEach(render);
  document.querySelectorAll('.f').forEach(b=>b.onclick=()=>{
    document.querySelectorAll('.f').forEach(x=>x.classList.remove('active'));
    b.classList.add('active');const f=b.dataset.f;
    document.querySelectorAll('.card').forEach(c=>{
      const show = f==='all' || (f==='retired'&&c.dataset.retired==='1') || (f==='active'&&c.dataset.retired!=='1') || c.dataset.arch===f;
      c.style.display=show?'':'none';
    });
  });
</script>
</body></html>
"@

Set-Content -Path (Join-Path $ReviewDir 'index.html') -Value $page -Encoding UTF8
Write-Host "Review page -> $ReviewDir\index.html" -ForegroundColor Green
Write-Host ("Verified {0} article(s); {1} with image-integrity issues." -f $manifest.Count, $totalIssues)
if ($totalIssues) { $verify | Where-Object { $_.issues.Count } | ForEach-Object { Write-Host ("  {0}: {1}" -f $_.stem, ($_.issues -join '; ')) -ForegroundColor Yellow } }
