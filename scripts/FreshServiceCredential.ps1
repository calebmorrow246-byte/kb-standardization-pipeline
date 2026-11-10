<#
.SYNOPSIS
    Store and retrieve the FreshService API key via Windows Credential Manager
    instead of a plaintext file, for Pull-/Push-/New-FreshServiceKBs.ps1.

.DESCRIPTION
    Run this script directly, once, to store your credentials:
        .\FreshServiceCredential.ps1 -Set
    It prompts for domain + API key (key input is masked) and writes them to
    Windows Credential Manager under target name "FreshServiceKB:api" (domain
    stored as the UserName field, API key as the CredentialBlob/password),
    persisted at CRED_PERSIST_LOCAL_MACHINE scope (survives reboots, scoped to
    your Windows account).

    Other scripts dot-source this file and call Get-FreshServiceCredential to
    read the stored value back:
        . (Join-Path $PSScriptRoot 'FreshServiceCredential.ps1')
        $creds = Get-FreshServiceCredential
        $creds.domain / $creds.api_key

.NOTES
    Uses the Win32 Credential Manager API (advapi32.dll CredRead/CredWrite)
    directly via P/Invoke - no external module dependency.
#>
[CmdletBinding()]
param(
    [switch]$Set,
    [switch]$Remove,
    [string]$Target = 'FreshServiceKB:api'
)

if (-not ('Win32Cred.NativeMethods' -as [type])) {
    Add-Type -Namespace Win32Cred -Name NativeMethods -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct CREDENTIAL {
    public int Flags;
    public int Type;
    public string TargetName;
    public string Comment;
    public long LastWritten;
    public int CredentialBlobSize;
    public IntPtr CredentialBlob;
    public int Persist;
    public int AttributeCount;
    public IntPtr Attributes;
    public string TargetAlias;
    public string UserName;
}

[DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool CredWrite(ref CREDENTIAL credential, uint flags);

[DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool CredRead(string target, int type, int reservedFlag, out IntPtr credentialPtr);

[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool CredDelete(string target, int type, int flags);

[DllImport("advapi32.dll")]
public static extern void CredFree(IntPtr cred);
'@
}

function Set-FreshServiceCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$ApiKey,
        [string]$Target = 'FreshServiceKB:api'
    )
    $blobBytes = [System.Text.Encoding]::Unicode.GetBytes($ApiKey)
    $blobPtr = [Runtime.InteropServices.Marshal]::AllocHGlobal($blobBytes.Length)
    try {
        [Runtime.InteropServices.Marshal]::Copy($blobBytes, 0, $blobPtr, $blobBytes.Length)
        $cred = New-Object Win32Cred.NativeMethods+CREDENTIAL
        $cred.Flags = 0
        $cred.Type = 1        # CRED_TYPE_GENERIC
        $cred.TargetName = $Target
        $cred.Comment = 'FreshService KB work - API key (see README.md)'
        $cred.CredentialBlobSize = $blobBytes.Length
        $cred.CredentialBlob = $blobPtr
        $cred.Persist = 2     # CRED_PERSIST_LOCAL_MACHINE
        $cred.UserName = $Domain
        $ok = [Win32Cred.NativeMethods]::CredWrite([ref]$cred, 0)
        if (-not $ok) {
            $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "CredWrite failed (Win32 error $err)"
        }
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($blobPtr)
    }
}

function Get-FreshServiceCredential {
    [CmdletBinding()]
    param([string]$Target = 'FreshServiceKB:api')
    $credPtr = [IntPtr]::Zero
    $ok = [Win32Cred.NativeMethods]::CredRead($Target, 1, 0, [ref]$credPtr)
    if (-not $ok) { return $null }
    try {
        $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($credPtr, [type][Win32Cred.NativeMethods+CREDENTIAL])
        $secretBytes = New-Object byte[] $cred.CredentialBlobSize
        [Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $secretBytes, 0, $cred.CredentialBlobSize)
        [PSCustomObject]@{
            domain  = $cred.UserName
            api_key = [System.Text.Encoding]::Unicode.GetString($secretBytes)
        }
    } finally {
        [Win32Cred.NativeMethods]::CredFree($credPtr)
    }
}

function Remove-FreshServiceCredential {
    [CmdletBinding()]
    param([string]$Target = 'FreshServiceKB:api')
    [Win32Cred.NativeMethods]::CredDelete($Target, 1, 0) | Out-Null
}

# --- Direct-invocation modes (setup / maintenance) -----------------------
if ($Set) {
    $domain = Read-Host 'FreshService domain (e.g. example.freshservice.com)'
    $secureKey = Read-Host 'API key' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    Set-FreshServiceCredential -Domain $domain -ApiKey $apiKey -Target $Target
    Write-Host "Stored in Windows Credential Manager under target '$Target'." -ForegroundColor Green
    $check = Get-FreshServiceCredential -Target $Target
    Write-Host "Verified round-trip OK for domain: $($check.domain)" -ForegroundColor Green
}
elseif ($Remove) {
    Remove-FreshServiceCredential -Target $Target
    Write-Host "Removed credential '$Target' (if it existed)." -ForegroundColor Yellow
}
