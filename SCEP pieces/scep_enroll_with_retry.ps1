<#
Author: Shayna Waldman 
Date: Nov 17, 2025
Desc: Enroll into Okta SCEP via FleetDM; retry with refetch if it fails
#>

param(
  [string]$FleetApiToken = "$FLEET_SECRET_API_TOKEN_FLEET",
  [string]$NodeName      = "<your_node>",
  [string]$FleetBaseUrl  = "https://<your_url>.fleetdm.com",
  #generate a random number for the MDM command ID
  [string]$CmdId         = (Get-Random -Minimum 100 -Maximum 99999999999999).ToString(),
  [int]$MaxRetries       = 5,
  [int]$RefetchWaitSec   = 20
)

$ErrorActionPreference = 'Stop'

# --- Tags path (create + hide root, but never delete folders) ---
$ProgramDataRoot  = [Environment]::GetFolderPath('CommonApplicationData')
$TagsRoot         = Join-Path $ProgramDataRoot 'IT'
$TagsPath         = Join-Path $TagsRoot 'Tags'
$EnrollFailedFile = Join-Path $TagsPath 'enroll_failed.txt'

function Ensure-TagsPath {
  if (-not (Test-Path -LiteralPath $TagsRoot)) { [void][IO.Directory]::CreateDirectory($TagsRoot); Write-Output "[Tags] Created $TagsRoot" }
  if (-not (Test-Path -LiteralPath $TagsPath)) { [void][IO.Directory]::CreateDirectory($TagsPath); Write-Output "[Tags] Created $TagsPath" }
  try { $ri = Get-Item -LiteralPath $TagsRoot -Force; if (-not ($ri.Attributes -band [IO.FileAttributes]::Hidden)) { $ri.Attributes = $ri.Attributes -bor [IO.FileAttributes]::Hidden; Write-Output "[Tags] Hid $TagsRoot" } } catch {}
}
function Write-Tag { Ensure-TagsPath; "Enroll failed at $(Get-Date -Format o)" | Out-File -LiteralPath $EnrollFailedFile -Encoding utf8 -Force }
function Clear-Tag { if (Test-Path -LiteralPath $EnrollFailedFile -PathType Leaf) { Remove-Item -LiteralPath $EnrollFailedFile -Force -ErrorAction SilentlyContinue } }

# --- Start ---
Ensure-TagsPath  # ensure path exists even if we early-exit
Write-Output "=== Start: $(Get-Date -Format o) ==="
Write-Output "ProgramDataRoot : $ProgramDataRoot"
Write-Output "FleetBaseUrl    : $FleetBaseUrl"
Write-Output "NodeName        : $NodeName"
Write-Output "CmdId           : $CmdId"
$Uuid = (Get-CimInstance -Class Win32_ComputerSystemProduct).UUID; Write-Output "Device UUID     : $Uuid"

# --- Build Exec (User channel) ---
function New-ExecB64 {
  param([string]$CmdId,[string]$NodeName)
  $xml = "<Exec>`n  <CmdID>$CmdId</CmdID>`n  <Item>`n    <Target>`n      <LocURI>./User/Vendor/MSFT/ClientCertificateInstall/SCEP/$NodeName/Install/Enroll</LocURI>`n    </Target>`n  </Item>`n</Exec>`n"
  [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($xml -replace "`r","")))
}

$CommandBase64 = New-ExecB64 -CmdId $CmdId -NodeName $NodeName
$uri     = "$FleetBaseUrl/api/v1/fleet/commands/run"
$headers = @{ Authorization = "Bearer $FleetApiToken" }
$body    = @{ host_uuids = @($Uuid); command = $CommandBase64 } | ConvertTo-Json -Depth 4

Write-Output "HTTP POST : $uri"
Write-Output "Body JSON : $body"

# --- Attempt + simple refetch on failure, limited retries ---
for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
  try {
    $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType "application/json" -Body $body
    Write-Output ("[Run] Success on attempt {0}" -f $attempt)
    Clear-Tag
    Write-Output "Done: $(Get-Date -Format o)"
    exit 0
  } catch {
    $err = $_ | Out-String
    Write-Output ("[Run] Failed attempt {0}: {1}" -f $attempt, $err.Trim())

    # Tag first, then simple one-shot refetch via Fleet API
    Write-Tag
    try {
      $hostId = (Invoke-RestMethod -Method Get -Uri "$FleetBaseUrl/api/v1/fleet/hosts/identifier/$Uuid" -Headers $headers).host.id
      Write-Output ("[Refetch] Host id {0}" -f $hostId)
      Invoke-RestMethod -Method Post -Uri "$FleetBaseUrl/api/v1/fleet/hosts/$hostId/refetch" -Headers $headers -ContentType "application/json" -Body "{}"
      Write-Output "[Refetch] Requested."
    } catch {
      Write-Output ("[Refetch] Error: {0}" -f ($_ | Out-String).Trim())
    }

    if ($attempt -lt $MaxRetries) { Write-Output ("[Retry] Sleeping {0}s..." -f $RefetchWaitSec); Start-Sleep -Seconds $RefetchWaitSec }
  }
}

Write-Output "[Run] All attempts failed; enroll_failed tag left in place."
exit 1
