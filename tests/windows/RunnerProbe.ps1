param(
  [Parameter(Mandatory = $true)]
  [string]$MarkerPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[System.IO.File]::WriteAllText($MarkerPath, "runner-ok", (New-Object System.Text.UTF8Encoding($false)))
