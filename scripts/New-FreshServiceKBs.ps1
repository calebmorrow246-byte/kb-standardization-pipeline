<#
.SYNOPSIS
    Creates brand-new Knowledge Base articles in FreshService via POST.

.DESCRIPTION
    Targets manifest entries where article_id == 0 and a final\<stem>.html exists.
    For each:
      1. POSTs to /api/v2/solutions/articles with title, description, folder_id,
         status (2=published), keywords, tags, review_date.
      2. Captures the returned article ID.
      3. Updates the manifest entry in-place with the real article_id and proper stem
         (categoryId_folderId_articleId).
      4. Renames converted\<old>.html and final\<old>.html to the new stem.
      5. Records the creation in review\pushed.json.

    Run with -DryRun first to verify the plan before creating anything live.

.PARAMETER DryRun
    Show what would be created; make no changes.
.PARAMETER Stem
    One or more stems to target (default: all manifest entries with article_id == 0).
.EXAMPLE
    .\New-FreshServiceKBs.ps1 -DryRun
    .\New-FreshServiceKBs.ps1
    .\New-FreshServiceKBs.ps1 -Stem new-wpengine-service-overview
#>
[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot,
    [switch]$DryRun,
    [string[]]$Stem,
    [int]$ThrottleMs = 400
)
$ErrorActionPreference = 'Stop'

# --- creds ---
. (Join-Path $PSScriptRoot 'FreshServiceCredential.ps1')
$creds = Get-FreshServiceCredential
if (-not $creds) { throw "No FreshService credential found. Run: .\FreshServiceCredential.ps1 -Set" }
$domain = ($creds.domain -replace '^https?://','' -replace '/$','')
$base   = "https://$domain/api/v2"
$basic  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($creds.api_key):X"))
$headers = @{ Authorization = "Basic $basic" }

$ConvertedDir = Join-Path $Root 'converted'
$FinalDir     = Join-Path $Root 'final'
$ReviewDir    = Join-Path $Root 'review'
$manifestPath = Join-Path $ReviewDir 'manifest.json'

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$pushedPath = Join-Path $ReviewDir 'pushed.json'
$pushedLog  = [System.Collections.Generic.List[object]]::new()
if (Test-Path $pushedPath) {
    foreach ($e in (Get-Content $pushedPath -Raw | ConvertFrom-Json)) { $pushedLog.Add($e) }
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

# Creates a solution article with file attachments in one multipart/form-data POST.
# Uses System.Net.Http directly rather than Invoke-RestMethod -Form: that cmdlet's
# array-of-FileInfo handling was verified (via a local HttpListener test) to
# inconsistently send some files as their path string instead of real file content.
function New-ArticleWithAttachments {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][long]$FolderId,
        [Parameter(Mandatory)][int]$Status,
        [string[]]$Keywords = @(),
        [string[]]$Tags = @(),
        [string]$ReviewDate,
        [Parameter(Mandatory)][string[]]$FilePaths
    )
    Add-Type -AssemblyName System.Net.Http

    $client = [System.Net.Http.HttpClient]::new()
    try {
        foreach ($h in $Headers.GetEnumerator()) {
            $client.DefaultRequestHeaders.TryAddWithoutValidation($h.Key, $h.Value) | Out-Null
        }

        $content = [System.Net.Http.MultipartFormDataContent]::new()
        $content.Add([System.Net.Http.StringContent]::new($Title), 'title')
        $content.Add([System.Net.Http.StringContent]::new($Description), 'description')
        $content.Add([System.Net.Http.StringContent]::new([string]$FolderId), 'folder_id')
        $content.Add([System.Net.Http.StringContent]::new([string]$Status), 'status')
        if ($ReviewDate) { $content.Add([System.Net.Http.StringContent]::new($ReviewDate), 'review_date') }
        foreach ($k in $Keywords) { $content.Add([System.Net.Http.StringContent]::new($k), 'keywords[]') }
        foreach ($t in $Tags) { $content.Add([System.Net.Http.StringContent]::new($t), 'tags[]') }

        $streams = [System.Collections.Generic.List[System.IO.FileStream]]::new()
        try {
            foreach ($fp in $FilePaths) {
                $stream = [System.IO.File]::OpenRead($fp)
                $streams.Add($stream)
                $fileContent = [System.Net.Http.StreamContent]::new($stream)
                $ext = [System.IO.Path]::GetExtension($fp).TrimStart('.').ToLower()
                $mime = switch ($ext) { 'png' { 'image/png' } 'jpg' { 'image/jpeg' } 'jpeg' { 'image/jpeg' } default { 'application/octet-stream' } }
                $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($mime)
                $content.Add($fileContent, 'attachments[]', [System.IO.Path]::GetFileName($fp))
            }

            $resp = $client.PostAsync($Uri, $content).GetAwaiter().GetResult()
            $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not $resp.IsSuccessStatusCode) {
                throw "HTTP $([int]$resp.StatusCode): $body"
            }
            return $body | ConvertFrom-Json
        }
        finally {
            foreach ($s in $streams) { $s.Dispose() }
        }
    }
    finally {
        $client.Dispose()
    }
}

# --- work list: manifest entries with article_id == 0 ---
$work = $manifest | Where-Object {
    ($_.article_id -eq 0) -and
    (Test-Path (Join-Path $FinalDir "$($_.stem).html")) -and
    (-not $Stem -or $Stem -contains $_.stem)
}

Write-Host ("Create plan: {0} article(s){1}" -f @($work).Count, $(if($DryRun){' [DRY RUN]'}else{''})) -ForegroundColor Cyan

if (-not @($work).Count) {
    Write-Host "Nothing to create. Ensure final\<stem>.html exists for each new entry and article_id is 0." -ForegroundColor Yellow
    exit 0
}

$ok = 0; $fail = 0

foreach ($r in $work) {
    $oldStem = $r.stem
    $desc    = Get-Content (Join-Path $FinalDir "$oldStem.html") -Raw
    $kw      = @($r.keywords -split ',\s*' | Where-Object { $_ })
    $tg      = @($r.tags)
    $fid     = [long]$r.folder_id

    $imgList = @($r.images | Sort-Object n)

    Write-Host ("  [new] {0}  (folder_id={1}){2}" -f $r.proposed_title, $fid, $(if ($imgList.Count) { " [$($imgList.Count) image(s)]" } else { '' }))

    if ($DryRun) {
        Write-Host ("      folder_id={0} kw={1} tags={2} desc={3}ch review={4}" -f $fid, $kw.Count, $tg.Count, $desc.Length, $r.review_date) -ForegroundColor DarkGray
        if ($imgList.Count) {
            foreach ($im in $imgList) {
                $fp = Join-Path $Root $im.file
                Write-Host ("      [[IMG:{0}]] -> {1} (exists={2})" -f $im.n, $im.file, (Test-Path $fp)) -ForegroundColor DarkGray
            }
        }
        continue
    }

    try {
        if ($imgList.Count) {
            $filePaths = $imgList | ForEach-Object { Join-Path $Root $_.file }
            foreach ($fp in $filePaths) {
                if (-not (Test-Path $fp)) { throw "Image file not found: $fp" }
            }

            $resp = Invoke-WithRetry {
                New-ArticleWithAttachments -Uri "$base/solutions/articles" -Headers $headers `
                    -Title $r.proposed_title -Description $desc -FolderId $fid -Status 2 `
                    -Keywords $kw -Tags $tg -ReviewDate $r.review_date -FilePaths $filePaths
            }
            $newId   = $resp.article.id
            $catId   = $resp.article.category_id
            $folId   = $resp.article.folder_id
            $newStem = "${catId}_${folId}_${newId}"

            $respAttachments = @($resp.article.attachments)
            if ($respAttachments.Count -ne $imgList.Count) {
                Write-Warning ("Expected {0} attachment(s), API returned {1} for '{2}' -- image embedding may be incomplete" -f $imgList.Count, $respAttachments.Count, $r.proposed_title)
            }

            # Match uploaded files to returned attachments by upload order (attachments[] was
            # sent in $imgList order). Cross-check the returned 'name' where present, but don't
            # depend on it -- FreshService's exact field name/behavior here wasn't documented
            # publicly enough to trust blindly.
            $finalDesc = $desc
            for ($i = 0; $i -lt $imgList.Count -and $i -lt $respAttachments.Count; $i++) {
                $n            = $imgList[$i].n
                $att          = $respAttachments[$i]
                $url          = $att.canonical_url
                if (-not $url) { $url = $att.attachment_url }
                if (-not $url) { throw "Attachment response for image n=$n had no canonical_url/attachment_url: $($att | ConvertTo-Json -Compress)" }
                $expectedName = [System.IO.Path]::GetFileName($filePaths[$i])
                if ($att.name -and $att.name -ne $expectedName) {
                    Write-Warning ("Attachment name mismatch for n={0}: expected '{1}', API returned '{2}' -- still matching by upload order" -f $n, $expectedName, $att.name)
                }
                # Escape '$' in the URL so -replace's replacement-string parser doesn't treat it as a capture-group reference.
                $safeUrl   = $url -replace '\$', '$$$$'
                $finalDesc = $finalDesc -replace [regex]::Escape("[[IMG:$n]]"), $safeUrl
            }
            if ($finalDesc -match '\[\[IMG:\d+\]\]') {
                Write-Warning ("Unresolved [[IMG:n]] placeholder(s) remain in '{0}' after image embedding" -f $r.proposed_title)
            }

            $putBody = @{ description = $finalDesc } | ConvertTo-Json -Depth 5
            Invoke-WithRetry { Invoke-RestMethod -Uri "$base/solutions/articles/$newId" -Headers $headers -Method Put -Body $putBody -ContentType 'application/json; charset=utf-8' } | Out-Null

            Write-Host ("      Created ID={0}  stem={1}  ({2} image(s) uploaded + embedded)" -f $newId, $newStem, $imgList.Count) -ForegroundColor Green

            # Images are now live on FreshService (recoverable via GET if ever
            # needed, see README.md section 6) -- the local assets\ copies are redundant.
            try {
                foreach ($fp in $filePaths) { if (Test-Path $fp) { Remove-Item $fp -Force } }
                $assetDirs = $filePaths | ForEach-Object { Split-Path $_ -Parent } | Sort-Object -Unique
                foreach ($dir in $assetDirs) {
                    if ((Test-Path $dir) -and -not (Get-ChildItem $dir -Force | Select-Object -First 1)) {
                        Remove-Item $dir -Force
                    }
                }
            } catch {
                Write-Warning "Article $newId pushed OK, but cleaning up local asset files failed: $_"
            }
        }
        else {
        $body = @{
            title       = $r.proposed_title
            description = $desc
            folder_id   = $fid
            status      = 2
            keywords    = $kw
            tags        = $tg
            review_date = $r.review_date
        } | ConvertTo-Json -Depth 5

        $resp      = Invoke-WithRetry { Invoke-RestMethod -Uri "$base/solutions/articles" -Headers $headers -Method Post -Body $body -ContentType 'application/json; charset=utf-8' }
        $newId     = $resp.article.id
        $catId     = $resp.article.category_id
        $folId     = $resp.article.folder_id
        $newStem   = "${catId}_${folId}_${newId}"

        Write-Host ("      Created ID={0}  stem={1}" -f $newId, $newStem) -ForegroundColor Green
        }

        # Rename files
        $oldConv = Join-Path $ConvertedDir "$oldStem.html"
        $newConv = Join-Path $ConvertedDir "$newStem.html"
        $oldFin  = Join-Path $FinalDir     "$oldStem.html"
        $newFin  = Join-Path $FinalDir     "$newStem.html"
        if (Test-Path $oldConv) { Rename-Item $oldConv $newConv }
        if (Test-Path $oldFin)  { Rename-Item $oldFin  $newFin  }

        # Update manifest entry in-place
        $r.article_id = $newId
        $r.stem       = $newStem

        $pushedLog.Add([ordered]@{
            article_id = $newId
            stem       = $newStem
            pushed_at  = (Get-Date).ToString('s')
            title      = $r.proposed_title
            fields     = @('title','description','folder_id','status','keywords','tags','review_date')
            action     = 'POST (new article)'
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
    # Write updated manifest (article_id and stem updated in-place on the objects)
    $manifest | ConvertTo-Json -Depth 6 | Set-Content $manifestPath -Encoding UTF8
    $pushedLog | ConvertTo-Json -Depth 5 | Set-Content $pushedPath -Encoding UTF8
    Write-Host ("Done. created={0} failed={1}. Manifest and pushed.json updated." -f $ok, $fail) -ForegroundColor Green
    if ($ok -gt 0) {
        Write-Host "Run .\Build-Review.ps1 to regenerate review\index.html with the updated stems." -ForegroundColor Cyan
    }
}
