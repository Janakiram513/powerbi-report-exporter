<#
.SYNOPSIS
    Exports a Power BI report from the Power BI / Fabric service as a Power BI Project (.pbip).

.DESCRIPTION
    Uses the Fabric REST API "Get Report Definition" call to download a report's definition
    (pages, visuals, bookmarks, filters) from any workspace where you have write access
    (Contributor, Member or Admin) and saves it as a .pbip project you can open in
    Power BI Desktop, diff, or commit to source control.

    Useful when the "Download this file" option is unavailable, or when only one
    environment (for example Development) is connected to Git and you need the
    version that is deployed to another environment.

    The call is read-only: nothing in the workspace is changed.

.PARAMETER WorkspaceId
    The workspace GUID - from the report URL: app.powerbi.com/groups/<WorkspaceId>/reports/<ReportId>

.PARAMETER ReportId
    The report GUID - from the same URL.

.PARAMETER Label
    Optional suffix for the output folder, e.g. DEV, UAT, PROD.

.PARAMETER OutputRoot
    Folder to save into. Default: Documents\PowerBI_Export

.PARAMETER UseBrowserToken
    Use an access token copied from the Power BI web page instead of signing in with Az.Accounts.

.NOTES
    PREREQUISITES
    - Workspace role on the REPORT's workspace: Admin, Member or Contributor.
      Viewer, direct/app sharing, or Build permission only -> 403 Forbidden.
    - Power BI licence giving access to the workspace (Pro / PPU, or free on Premium/Fabric capacity).
    - Organisation allows Power BI / Fabric REST API access.
    - Encrypted sensitivity label: you need rights to remove the label.
    - Windows PowerShell 5.1 or PowerShell 7+.
    - Sign-in: Az.Accounts module (auto-installed for current user, needs PowerShell Gallery access)
      or -UseBrowserToken with an app.powerbi.com browser session.
    - A recent Power BI Desktop to open the exported .pbip.
    Run as a file (powershell -ExecutionPolicy Bypass -File ...), not by pasting into the console.

.EXAMPLE
    .\Export-PbiReport.ps1 -WorkspaceId "<workspace-guid>" -ReportId "<report-guid>" -Label PROD

.EXAMPLE
    .\Export-PbiReport.ps1 -WorkspaceId "<workspace-guid>" -ReportId "<report-guid>" -UseBrowserToken
#>
param(
    [Parameter(Mandatory = $true)][string]$WorkspaceId,
    [Parameter(Mandatory = $true)][string]$ReportId,
    [string]$Label = "",
    [string]$OutputRoot = "$HOME\Documents\PowerBI_Export",
    [switch]$UseBrowserToken
)

$ErrorActionPreference = "Stop"
$api = "https://api.fabric.microsoft.com/v1"

# ------------------------------------------------------------------ 1. Access token
if ($UseBrowserToken) {
    Write-Host "Open https://app.powerbi.com, press F12 > Console, run:  copy(powerBIAccessToken)" -ForegroundColor Cyan
    Read-Host "Then press Enter here"
    $token = (Get-Clipboard | Out-String).Trim()
    if ($token.Length -lt 100) { throw "No token found on the clipboard." }
} else {
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-Host "Installing Az.Accounts for the current user (one time)..." -ForegroundColor Cyan
        Install-Module Az.Accounts -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module Az.Accounts
    Connect-AzAccount -WarningAction SilentlyContinue | Out-Null
    try {
        $t = Get-AzAccessToken -ResourceUrl "https://api.fabric.microsoft.com" -AsSecureString -WarningAction SilentlyContinue
        $token = [System.Net.NetworkCredential]::new('', $t.Token).Password
    } catch {
        $t = Get-AzAccessToken -ResourceUrl "https://api.fabric.microsoft.com" -WarningAction SilentlyContinue
        if ($t.Token -is [securestring]) { $token = [System.Net.NetworkCredential]::new('', $t.Token).Password } else { $token = $t.Token }
    }
}
if (-not $token) { throw "Could not obtain an access token." }
$headers = @{ Authorization = "Bearer $token" }

function Invoke-Api([string]$Method, [string]$Uri) {
    try {
        return Invoke-WebRequest -Method $Method -Headers $headers -UseBasicParsing -Uri $Uri
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 401) { throw "401 Unauthorized - token missing or expired. Sign in again or use -UseBrowserToken." }
        elseif ($code -eq 403) { throw "403 Forbidden - you need write access (Contributor/Member/Admin) on the workspace, or Fabric APIs are disabled in your tenant." }
        elseif ($code -eq 404) { throw "404 Not Found - check the workspace and report IDs." }
        else { throw }
    }
}

# ------------------------------------------------------------------ 2. Report name
$meta = (Invoke-Api Get "$api/workspaces/$WorkspaceId/reports/$ReportId").Content | ConvertFrom-Json
$reportName = $meta.displayName
Write-Host "Exporting '$reportName' ..." -ForegroundColor Cyan

# ------------------------------------------------------------------ 3. Definition (long-running operation aware)
$resp = Invoke-Api Post "$api/workspaces/$WorkspaceId/reports/$ReportId/getDefinition"
if ($resp.StatusCode -eq 202) {
    $opUrl = "$($resp.Headers['Location'])"
    do {
        Start-Sleep -Seconds 5
        $state = Invoke-RestMethod -Uri $opUrl -Headers $headers
        Write-Host "  status: $($state.status)"
    } while ($state.status -notin @('Succeeded', 'Failed'))
    if ($state.status -eq 'Failed') { throw "Export failed: $($state | ConvertTo-Json -Depth 6)" }
    $definition = Invoke-RestMethod -Uri "$opUrl/result" -Headers $headers
} else {
    $definition = $resp.Content | ConvertFrom-Json
}
if (-not $definition.definition.parts) { throw "The service returned no definition parts." }

# ------------------------------------------------------------------ 4. Write the .pbip project
$safeName = ($reportName -replace '[\\/:*?"<>|]', '_')
if ($Label) { $safeName = "${safeName}_$Label" }
$projectDir = Join-Path $OutputRoot $safeName
$reportDir  = Join-Path $projectDir "$safeName.Report"
if (Test-Path $reportDir) { Remove-Item $reportDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

foreach ($part in $definition.definition.parts) {
    $file = Join-Path $reportDir $part.path
    New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
    [IO.File]::WriteAllBytes($file, [Convert]::FromBase64String($part.payload))
}

$pbip = [ordered]@{
    '$schema' = "https://developer.microsoft.com/json-schemas/fabric/pbip/pbipProperties/1.0.0/schema.json"
    version   = "1.0"
    artifacts = @(@{ report = @{ path = "$safeName.Report" } })
    settings  = @{ enableAutoRecovery = $true }
}
$pbipFile = Join-Path $projectDir "$safeName.pbip"
[IO.File]::WriteAllText($pbipFile, ($pbip | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))

Write-Host "Done - $($definition.definition.parts.Count) files saved to $projectDir" -ForegroundColor Green
Write-Host "Note: the project is live-connected to its semantic model. Avoid publishing from an exported copy unless you intend to overwrite the original." -ForegroundColor Yellow
