Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'DataSafe.Safety.ps1')

# Version-2 repository.json UTF-8 schema:
# { "formatVersion": 2, "computerId": "<non-empty D-format UUID>",
#   "computerName": "<original friendly Windows computer name>" }
# Local identity state uses { "formatVersion": 1, "computerId": "<UUID>" }.
# Paths are derived, never trusted from JSON. Future manifest pointers can be
# added without changing the identity fields or the ordinary-file layout.
function Assert-DataSafeComputerId([string]$ComputerId) {
  $parsed = [guid]::Empty
  if (-not [guid]::TryParseExact($ComputerId, 'D', [ref]$parsed) -or $parsed -eq [guid]::Empty) {
    throw 'DataSafe computer identity must be a non-empty UUID in D format.'
  }
}

function Read-DataSafeStrictJsonValue($Tokens, $Cursor, [int]$Depth) {
  $invalid = 'DataSafe identity metadata requires standard JSON syntax.'
  if ($Cursor.Position -ge $Tokens.Count -or $Depth -gt 64) { throw $invalid }
  $token = $Tokens[$Cursor.Position]
  $Cursor.Position++
  if ($token -eq '{') {
    $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if ($Cursor.Position -lt $Tokens.Count -and $Tokens[$Cursor.Position] -eq '}') { $Cursor.Position++; return }
    while ($Cursor.Position -lt $Tokens.Count) {
      $keyToken = $Tokens[$Cursor.Position]
      if (-not $keyToken.StartsWith('"')) { throw $invalid }
      # Manifests reuse the strict parser and contain nested source/entry
      # objects. Reject ambiguous keys before ConvertFrom-Json at every depth.
      $key = ConvertFrom-Json -InputObject $keyToken -ErrorAction Stop
      if (-not $keys.Add($key)) { throw "DataSafe identity metadata contains a duplicate JSON property: $key" }
      $Cursor.Position++
      if ($Cursor.Position -ge $Tokens.Count -or $Tokens[$Cursor.Position] -ne ':') { throw $invalid }
      $Cursor.Position++
      Read-DataSafeStrictJsonValue $Tokens $Cursor ($Depth + 1)
      if ($Cursor.Position -ge $Tokens.Count) { throw $invalid }
      $separator = $Tokens[$Cursor.Position]
      $Cursor.Position++
      if ($separator -eq '}') { return }
      if ($separator -ne ',') { throw $invalid }
    }
    throw $invalid
  }
  if ($token -eq '[') {
    if ($Cursor.Position -lt $Tokens.Count -and $Tokens[$Cursor.Position] -eq ']') { $Cursor.Position++; return }
    while ($Cursor.Position -lt $Tokens.Count) {
      Read-DataSafeStrictJsonValue $Tokens $Cursor ($Depth + 1)
      if ($Cursor.Position -ge $Tokens.Count) { throw $invalid }
      $separator = $Tokens[$Cursor.Position]
      $Cursor.Position++
      if ($separator -eq ']') { return }
      if ($separator -ne ',') { throw $invalid }
    }
    throw $invalid
  }
  # The lexer already validated complete strings, numbers, and literals.
  if ($token -notmatch '^(?:"|-|[0-9]|true$|false$|null$)') { throw $invalid }
}

function Assert-DataSafeIdentityJsonShape([string]$Json) {
  # ConvertFrom-Json accepts nonstandard syntax on both supported engines.
  # Tokenize every character strictly before conversion can collapse keys or
  # ignore comments. Only JSON whitespace, escapes, numbers and literals pass.
  $lexer = New-Object regex('\G(?:[ \t\r\n]+|(?<token>"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null|[{}\[\]:,]))')
  $tokens = New-Object 'System.Collections.Generic.List[string]'
  $position = 0
  while ($position -lt $Json.Length) {
    $match = $lexer.Match($Json, $position)
    if (-not $match.Success) { throw 'DataSafe identity metadata requires standard JSON syntax.' }
    if ($match.Groups['token'].Success) { $tokens.Add($match.Groups['token'].Value) }
    $position += $match.Length
  }
  if ($tokens.Count -eq 0 -or $tokens[0] -ne '{') { throw 'DataSafe identity metadata requires one top-level JSON object.' }
  $cursor = @{ Position = 0 }
  Read-DataSafeStrictJsonValue $tokens $cursor 0
  if ($cursor.Position -ne $tokens.Count) { throw 'DataSafe identity metadata requires one top-level JSON object.' }
}

function Read-DataSafeRepositoryJson([string]$Path) {
  Assert-DataSafeNoReparsePath $Path
  if (-not (Test-DataSafeFile $Path)) { throw "DataSafe repository or identity state JSON is missing: $Path" }
  try {
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    $json = [System.IO.File]::ReadAllText((ConvertTo-DataSafeExtendedPath $Path), $encoding)
    Assert-DataSafeIdentityJsonShape $json
    $result = ConvertFrom-Json -InputObject $json -ErrorAction Stop
    if ($null -eq $result -or $result -isnot [PSCustomObject]) { throw 'Expected a JSON object.' }
    return $result
  } catch { throw "DataSafe repository or identity state JSON is invalid: $($_.Exception.Message)" }
}

function Assert-DataSafeIdentitySchema($Value, [int]$Version) {
  $format = Get-DataSafeProperty $Value 'formatVersion'
  $identity = Get-DataSafeProperty $Value 'computerId'
  if (($format -isnot [int] -and $format -isnot [long]) -or $format -ne $Version -or $identity -isnot [string]) {
    throw 'DataSafe repository or identity state schema is invalid or unsupported.'
  }
  Assert-DataSafeComputerId $identity
}

function Get-DataSafeComputerId([string]$StatePath) {
  Assert-DataSafeNoReparsePath $StatePath
  if (-not (Test-DataSafeFile $StatePath)) {
    $newState = [ordered]@{ formatVersion = 1; computerId = [guid]::NewGuid().ToString('D') }
    try { Write-DataSafeAtomicJson $StatePath $newState -CreateOnly } catch {
      # A concurrent initializer may have published first. Read and validate the
      # winner; do not replace invalid state or suppress unrelated write errors.
      if (-not (Test-DataSafeFile $StatePath)) { throw }
    }
  }
  $state = Read-DataSafeRepositoryJson $StatePath
  Assert-DataSafeIdentitySchema $state 1
  return $state.computerId
}

# Pure mapping seam for unit tests; actual destination detection stays separate.
function Get-DataSafeFilesystemCapabilities([string]$FileSystem) {
  $name = $FileSystem.ToUpperInvariant()
  $supported = $name -in @('NTFS', 'EXFAT', 'FAT32')
  return [PSCustomObject]@{
    FileSystem = $FileSystem
    Supported = $supported
    Recommended = $name -eq 'NTFS'
    CompatibilityMode = $name -eq 'FAT32'
    MaxFileBytes = $(if ($name -eq 'FAT32') { [long]4294967295 } elseif ($supported) { [long]::MaxValue } else { [long]0 })
    TimestampToleranceTicks = $(if ($name -eq 'NTFS') { [long]0 } elseif ($name -eq 'EXFAT') { [long]100000 } elseif ($name -eq 'FAT32') { [long]20000000 } else { [long]-1 })
  }
}

function Get-DataSafeDestinationCapabilities([string]$DriveRoot) {
  Assert-DataSafeNoReparsePath $DriveRoot
  if (-not (Test-DataSafeDirectory $DriveRoot)) { throw 'DataSafe destination drive is unavailable.' }
  $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath((ConvertFrom-DataSafeExtendedPath $DriveRoot)))
  $drive = New-Object System.IO.DriveInfo($root)
  if (-not $drive.IsReady) { throw 'DataSafe destination drive is unavailable.' }
  $capabilities = Get-DataSafeFilesystemCapabilities $drive.DriveFormat
  $capabilities | Add-Member -NotePropertyName TotalBytes -NotePropertyValue ([long]$drive.TotalSize)
  return $capabilities
}

function ConvertTo-DataSafeComputerSegment([string]$ComputerName) {
  if ([string]::IsNullOrWhiteSpace($ComputerName)) { throw 'DataSafe requires a computer name.' }
  $segment = [regex]::Replace($ComputerName, '[<>:"/\\|?*\x00-\x1f]', '_').Trim().TrimEnd('.', ' ')
  if ([string]::IsNullOrWhiteSpace($segment)) { $segment = 'Computer' }
  # Reserve enough component space for the deterministic full UUID suffix.
  if ($segment.Length -gt 100) { $segment = $segment.Substring(0, 100).TrimEnd('.', ' ') }
  if ($segment -match '^(?i:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(?:\.|$)') { $segment = '_' + $segment }
  return $segment
}

function Read-DataSafeRepository([string]$RepositoryRoot) {
  Assert-DataSafeNoReparsePath $RepositoryRoot
  $root = [System.IO.Path]::GetFullPath((ConvertFrom-DataSafeExtendedPath $RepositoryRoot))
  $metadataRoot = Join-Path $root '.datasafe'
  $metadata = Read-DataSafeRepositoryJson (Join-Path $metadataRoot 'repository.json')
  Assert-DataSafeIdentitySchema $metadata 2
  $name = Get-DataSafeProperty $metadata 'computerName'
  if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name)) { throw 'DataSafe repository computer-name schema is invalid.' }
  $result = [PSCustomObject]@{
    FormatVersion = 2
    ComputerId = $metadata.computerId
    ComputerName = $name
    Root = $root
    LatestRoot = Join-Path $root 'Latest Backup'
    HistoryRoot = Join-Path $root 'Earlier Versions'
    MetadataRoot = $metadataRoot
    ManifestRoot = Join-Path $metadataRoot 'manifests'
    TransactionRoot = Join-Path $metadataRoot 'transactions'
    StagingRoot = Join-Path $metadataRoot 'staging'
  }
  foreach ($path in @($result.LatestRoot, $result.HistoryRoot, $result.ManifestRoot, $result.TransactionRoot, $result.StagingRoot)) {
    Assert-DataSafeNoReparsePath $path
    if (-not (Test-DataSafeDirectory $path)) { throw "DataSafe repository layout is incomplete: $path" }
  }
  return $result
}

function Initialize-DataSafeRepository([string]$DriveRoot, [string]$ComputerName, [string]$ComputerId) {
  Assert-DataSafeComputerId $ComputerId
  $segment = ConvertTo-DataSafeComputerSegment $ComputerName
  Assert-DataSafeNoReparsePath $DriveRoot
  if (-not (Test-DataSafeDirectory $DriveRoot)) { throw 'DataSafe destination drive is unavailable.' }
  $baseRoot = Join-Path ([System.IO.Path]::GetFullPath((ConvertFrom-DataSafeExtendedPath $DriveRoot))) 'DataSafe Backups'
  Assert-DataSafeNoReparsePath $baseRoot
  Ensure-DataSafeDirectory $baseRoot
  $matching = $null
  foreach ($child in @([System.IO.Directory]::GetDirectories((ConvertTo-DataSafeExtendedPath $baseRoot)))) {
    $childRoot = ConvertFrom-DataSafeExtendedPath $child
    # Reparse entries are not repositories and must never be traversed.
    $attributes = [System.IO.File]::GetAttributes($child)
    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
    $metadataRoot = Join-Path $childRoot '.datasafe'
    Assert-DataSafeNoReparsePath $metadataRoot
    if (Test-DataSafeDirectory $metadataRoot) {
      $existing = Read-DataSafeRepository $childRoot
      if ([guid]$existing.ComputerId -eq [guid]$ComputerId) {
        if ($null -ne $matching) { throw 'DataSafe repository identity is duplicated on this destination.' }
        $matching = $existing
      }
    }
  }
  if ($null -ne $matching) { return $matching }

  $root = Join-Path $baseRoot $segment
  Assert-DataSafeNoReparsePath $root
  if ((Test-DataSafeDirectory $root) -or (Test-DataSafeFile $root)) {
    $root = Join-Path $baseRoot ($segment + ' (' + ([guid]$ComputerId).ToString('D') + ')')
    Assert-DataSafeNoReparsePath $root
    if ((Test-DataSafeDirectory $root) -or (Test-DataSafeFile $root)) {
      throw 'DataSafe deterministic repository folder is already occupied; review the destination identity before continuing.'
    }
  }
  foreach ($relative in @('Latest Backup', 'Earlier Versions', '.datasafe/manifests', '.datasafe/transactions', '.datasafe/staging')) {
    $path = Join-Path $root $relative
    Assert-DataSafeNoReparsePath $path
    Ensure-DataSafeDirectory $path
  }
  $metadata = [ordered]@{ formatVersion = 2; computerId = $ComputerId; computerName = $ComputerName }
  Write-DataSafeAtomicJson (Join-Path $root '.datasafe/repository.json') $metadata -CreateOnly
  return Read-DataSafeRepository $root
}
