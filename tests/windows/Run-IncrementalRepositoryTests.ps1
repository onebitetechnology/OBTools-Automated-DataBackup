param([string]$WindowsRoot = (Join-Path $PSScriptRoot '../../windows'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$passes = New-Object 'System.Collections.Generic.List[string]'
$failures = New-Object 'System.Collections.Generic.List[string]'
function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
  try { & $Action | Out-Null } catch {
    if ($_.Exception -is [System.Management.Automation.CommandNotFoundException]) { throw }
    Assert-True ($_.Exception.Message -match $Pattern) "Unexpected error: $($_.Exception.Message)"
    return
  }
  throw 'Expected rejection, but operation succeeded.'
}
function Test-Case([string]$Name, [scriptblock]$Action) {
  try { & $Action; $passes.Add($Name) } catch { $failures.Add("${Name}: $($_.Exception.Message)") }
}
function New-TestRepositoryLayout([string]$Root) {
  foreach ($relative in @('Latest Backup', 'Earlier Versions', '.datasafe/manifests', '.datasafe/transactions', '.datasafe/staging')) {
    Ensure-DataSafeDirectory (Join-Path $Root $relative)
  }
}

. (Join-Path $WindowsRoot 'DataSafe.Safety.ps1')
$library = Join-Path $WindowsRoot 'DataSafe.Repository.ps1'
if (Test-Path -LiteralPath $library) { . $library }

# Capability mapping is pure so this subset also runs on non-Windows hosts.
foreach ($row in @(
  @{ Name = 'NTFS'; Recommended = $true; Compatibility = $false; Limit = [long]::MaxValue },
  @{ Name = 'exFAT'; Recommended = $false; Compatibility = $false; Limit = [long]::MaxValue },
  @{ Name = 'FAT32'; Recommended = $false; Compatibility = $true; Limit = [long]4294967295 }
)) {
  Test-Case "$($row.Name) capability mapping" {
    $actual = Get-DataSafeFilesystemCapabilities -FileSystem $row.Name
    Assert-True ($actual.Supported -and $actual.Recommended -eq $row.Recommended) 'Incorrect support/recommendation.'
    Assert-True ($actual.CompatibilityMode -eq $row.Compatibility -and $actual.MaxFileBytes -eq $row.Limit) 'Incorrect file limit/compatibility mode.'
  }
}
Test-Case 'unknown filesystem fails closed' {
  Assert-True (-not (Get-DataSafeFilesystemCapabilities -FileSystem 'unknown').Supported) 'Unknown filesystem was supported.'
}

if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('datasafe-repository-tests-' + [guid]::NewGuid().ToString('N'))
  Ensure-DataSafeDirectory $tempRoot
  $id1 = '00112233-4455-4677-8899-aabbccddeeff'
  $id2 = '10112233-4455-4677-8899-aabbccddeeff'
  $driveRoot = Join-Path $tempRoot 'drive'
  Ensure-DataSafeDirectory $driveRoot
  try {
    Test-Case 'initialization creates ordinary layout and explicit UTF-8 identity metadata' {
      $repository = Initialize-DataSafeRepository $driveRoot 'Office PC' $id1
      Assert-True ($repository.Root -eq (Join-Path $driveRoot 'DataSafe Backups/Office PC')) 'Unexpected friendly root.'
      foreach ($path in @('Latest Backup', 'Earlier Versions', '.datasafe/manifests', '.datasafe/transactions', '.datasafe/staging')) {
        Assert-True (Test-DataSafeDirectory (Join-Path $repository.Root $path)) "Missing $path"
      }
      $expectedProperties = @('FormatVersion','ComputerId','ComputerName','Root','LatestRoot','HistoryRoot','MetadataRoot','ManifestRoot','TransactionRoot','StagingRoot')
      Assert-True (@($repository.PSObject.Properties.Name).Count -eq $expectedProperties.Count) 'Unexpected result shape.'
      foreach ($name in $expectedProperties) { Assert-True ($null -ne $repository.PSObject.Properties[$name]) "Missing $name" }
      $metadataPath = Join-Path $repository.MetadataRoot 'repository.json'
      $bytes = [IO.File]::ReadAllBytes((ConvertTo-DataSafeExtendedPath $metadataPath))
      Assert-True (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'Metadata must use UTF-8 without BOM.'
      $json = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
      Assert-True ($json.formatVersion -eq 2 -and $json.computerId -ceq $id1 -and $json.computerName -ceq 'Office PC') 'Incorrect metadata identity/schema.'
      Assert-True ((Read-DataSafeRepository $repository.Root).ComputerId -ceq $id1) 'Read did not preserve UUID.'
    }
    Test-Case 'same friendly name isolates UUIDs and repeated initialization is stable' {
      $first = Initialize-DataSafeRepository $driveRoot 'Office PC' $id1
      $second = Initialize-DataSafeRepository $driveRoot 'Office PC' $id2
      Assert-True ($second.Root -ne $first.Root -and (Split-Path -Leaf $second.Root).StartsWith('Office PC (')) 'Collision did not use a separate suffixed folder.'
      Assert-True ((Split-Path -Leaf $second.Root) -ceq 'Office PC (10112233-4455-4677-8899-aabbccddeeff)') 'Collision suffix is not deterministic.'
      Assert-True ($second.ComputerId -ceq $id2 -and (Read-DataSafeRepository $first.Root).ComputerId -ceq $id1) 'Collision mixed UUID identities.'
      Assert-True ((Initialize-DataSafeRepository $driveRoot 'Office PC' $id2).Root -eq $second.Root) 'Repeated collision changed root.'
      Assert-True ((Initialize-DataSafeRepository $driveRoot 'Renamed PC' $id1).Root -eq $first.Root) 'Friendly rename lost authoritative identity.'
    }
    Test-Case 'sanitization preserves original name and exact UUID spelling' {
      $original = 'CON:<PC>/ ' + [char]0x00e9
      $identity = 'ABCDEF01-2345-4678-9ABC-DEF012345678'
      $result = Initialize-DataSafeRepository $driveRoot $original $identity
      $leaf = Split-Path -Leaf $result.Root
      Assert-True ($leaf -notmatch '[<>:"/\\|?*]' -and $leaf -notmatch '[. ]$') 'Unsafe friendly segment.'
      Assert-True ($result.ComputerName -ceq $original -and $result.ComputerId -ceq $identity) 'Sanitization changed metadata.'
      Assert-True ((Read-DataSafeRepository $result.Root).ComputerName -ceq $original) 'UTF-8 name did not round trip.'
      $reserved = Initialize-DataSafeRepository $driveRoot 'NUL' ([guid]::NewGuid().ToString())
      Assert-True ((Split-Path -Leaf $reserved.Root) -ne 'NUL') 'Reserved device name used verbatim.'
    }
    Test-Case 'computer identity creation is durable stable and invalid state is never overwritten' {
      $statePath = Join-Path $tempRoot 'state/computer.json'
      $first = Get-DataSafeComputerId $statePath
      Assert-True ([guid]::Parse($first) -ne [guid]::Empty) 'Invalid generated identity.'
      Assert-True ((Get-DataSafeComputerId $statePath) -ceq $first) 'Identity changed on reread.'
      [IO.File]::WriteAllText((ConvertTo-DataSafeExtendedPath $statePath), '{broken')
      Assert-Throws { Get-DataSafeComputerId $statePath } 'identity|JSON|state'
      Assert-True ([IO.File]::ReadAllText((ConvertTo-DataSafeExtendedPath $statePath)) -ceq '{broken') 'Corrupt identity was overwritten.'
    }
    Test-Case 'repository reader rejects missing corrupt wrong-version and invalid-UUID metadata' {
      foreach ($row in @(
        @{ Json = '{broken'; Error = 'JSON is invalid' },
        @{ Json = '{"formatVersion":1,"computerId":"00112233-4455-4677-8899-aabbccddeeff","computerName":"PC"}'; Error = 'schema is invalid' },
        @{ Json = '{"formatVersion":"2","computerId":"00112233-4455-4677-8899-aabbccddeeff","computerName":"PC"}'; Error = 'schema is invalid' },
        @{ Json = '{"formatVersion":2,"computerId":"bad","computerName":"PC"}'; Error = 'computer identity must' },
        @{ Json = '{"formatVersion":2,"computerId":"00000000-0000-0000-0000-000000000000","computerName":"PC"}'; Error = 'computer identity must' },
        @{ Json = '{"formatVersion":2,"computerId":"00112233-4455-4677-8899-aabbccddeeff"}'; Error = 'computer-name schema is invalid' }
      )) {
        $root = Join-Path $tempRoot ([guid]::NewGuid().ToString('N'))
        New-TestRepositoryLayout $root
        [IO.File]::WriteAllText((ConvertTo-DataSafeExtendedPath (Join-Path $root '.datasafe/repository.json')), $row.Json)
        Assert-Throws { Read-DataSafeRepository $root } $row.Error
      }
      Assert-Throws { Read-DataSafeRepository (Join-Path $tempRoot 'missing') } 'JSON is missing'
    }
    foreach ($case in @(
      @{ Name = 'duplicate UUID'; Json = '{"formatVersion":VERSION,"computerId":"00112233-4455-4677-8899-aabbccddeeff","computerId":"10112233-4455-4677-8899-aabbccddeeff","computerName":"PC"}'; Error = 'duplicate' },
      @{ Name = 'escaped duplicate UUID key'; Json = '{"formatVersion":VERSION,"computerId":"00112233-4455-4677-8899-aabbccddeeff","computer\u0049d":"10112233-4455-4677-8899-aabbccddeeff","computerName":"PC"}'; Error = 'duplicate' },
      @{ Name = 'duplicate schema version'; Json = '{"formatVersion":0,"formatVersion":VERSION,"computerId":"00112233-4455-4677-8899-aabbccddeeff","computerName":"PC"}'; Error = 'duplicate' },
      @{ Name = 'duplicate friendly name'; Json = '{"formatVersion":VERSION,"computerId":"00112233-4455-4677-8899-aabbccddeeff","computerName":"Original","computerName":"PC"}'; Error = 'duplicate' },
      @{ Name = 'unquoted duplicate UUID'; Json = '{"formatVersion":VERSION,"computerId":"00112233-4455-4677-8899-aabbccddeeff","computerName":"PC",computerId:"10112233-4455-4677-8899-aabbccddeeff"}'; Error = 'standard JSON' },
      @{ Name = 'single-quoted duplicate UUID'; Json = '{"formatVersion":VERSION,"computerId":"00112233-4455-4677-8899-aabbccddeeff","computerName":"PC",''computerId'':"10112233-4455-4677-8899-aabbccddeeff"}'; Error = 'standard JSON' },
      @{ Name = 'single-quoted escaped duplicate UUID'; Json = '{"formatVersion":VERSION,"computerId":"00112233-4455-4677-8899-aabbccddeeff","computerName":"PC",''computer\u0049d'':"10112233-4455-4677-8899-aabbccddeeff"}'; Error = 'standard JSON' },
      @{ Name = 'comment-depth duplicate UUID'; Json = '{"formatVersion":VERSION,"computerId":"00112233-4455-4677-8899-aabbccddeeff","computerName":"PC", /* [ */ "computerId":"10112233-4455-4677-8899-aabbccddeeff" /* ] */}'; Error = 'standard JSON' },
      @{ Name = 'comment-depth escaped duplicate UUID'; Json = '{"formatVersion":VERSION,"computerId":"00112233-4455-4677-8899-aabbccddeeff","computerName":"PC", /* [ */ "computer\u0049d":"10112233-4455-4677-8899-aabbccddeeff" /* ] */}'; Error = 'standard JSON' },
      @{ Name = 'unquoted duplicate schema version'; Json = '{"formatVersion":0,"computerId":"00112233-4455-4677-8899-aabbccddeeff","computerName":"PC",formatVersion:VERSION}'; Error = 'standard JSON' },
      @{ Name = 'nonstandard trailing comma'; Json = '{"formatVersion":VERSION,"computerId":"00112233-4455-4677-8899-aabbccddeeff","computerName":"PC",}'; Error = 'standard JSON' },
      @{ Name = 'unquoted keyword property'; Json = '{"formatVersion":VERSION,"computerId":"00112233-4455-4677-8899-aabbccddeeff","computerName":"PC",true:0}'; Error = 'standard JSON' },
      @{ Name = 'singleton object array'; Json = '[{"formatVersion":VERSION,"computerId":"00112233-4455-4677-8899-aabbccddeeff","computerName":"PC"}]'; Error = 'top-level JSON object' }
    )) {
      Test-Case "$($case.Name) rejected for complete repository" {
        $root = Join-Path $tempRoot ([guid]::NewGuid().ToString('N'))
        New-TestRepositoryLayout $root
        $repositoryJson = $case.Json.Replace('VERSION', '2')
        [IO.File]::WriteAllText((ConvertTo-DataSafeExtendedPath (Join-Path $root '.datasafe/repository.json')), $repositoryJson)
        Assert-Throws { Read-DataSafeRepository $root } $case.Error
      }
      Test-Case "$($case.Name) rejected for local identity state" {
        $statePath = Join-Path $tempRoot ([guid]::NewGuid().ToString('N') + '.json')
        $stateJson = $case.Json.Replace('VERSION', '1')
        [IO.File]::WriteAllText((ConvertTo-DataSafeExtendedPath $statePath), $stateJson)
        Assert-Throws { Get-DataSafeComputerId $statePath } $case.Error
        Assert-True ([IO.File]::ReadAllText((ConvertTo-DataSafeExtendedPath $statePath)) -ceq $stateJson) 'Ambiguous local state was changed.'
      }
    }
    Test-Case 'standard JSON whitespace Unicode escapes nested extensions and BOM remain valid for both readers' {
      $root = Join-Path $tempRoot 'strict-json-positive'
      New-TestRepositoryLayout $root
      $template = " `t`r`n" + '{"formatVersion":VERSION,"computer\u0049d":"00112233-4455-4677-8899-aabbccddeeff","computerName":"PC \u00e9 \\\"quote\\\"","extension":{"list":[null,true,false,-12.5e+2,{},[],{"text":"/* [ ] */ } { \\ \/ \b \f \n \r \t"}]}}' + "`r`n"
      $encoding = New-Object Text.UTF8Encoding($true)
      $repositoryPath = Join-Path $root '.datasafe/repository.json'
      [IO.File]::WriteAllText((ConvertTo-DataSafeExtendedPath $repositoryPath), $template.Replace('VERSION', '2'), $encoding)
      $result = Read-DataSafeRepository $root
      Assert-True ($result.ComputerId -ceq $id1 -and $result.ComputerName.Contains([string][char]0x00e9)) 'Valid standard JSON metadata was not preserved.'
      $statePath = Join-Path $root 'state.json'
      [IO.File]::WriteAllText((ConvertTo-DataSafeExtendedPath $statePath), $template.Replace('VERSION', '1'), $encoding)
      Assert-True ((Get-DataSafeComputerId $statePath) -ceq $id1) 'Valid standard JSON identity state was rejected.'
    }
    Test-Case 'superscript serial and printer device names are browseable with original metadata preserved' {
      foreach ($prefix in @('COM','LPT')) {
        foreach ($digit in @([char]0x00b9, [char]0x00b2, [char]0x00b3)) {
          foreach ($extension in @('', '.files')) {
            $name = $prefix + $digit + $extension
            $result = Initialize-DataSafeRepository $driveRoot $name ([guid]::NewGuid().ToString('D'))
            Assert-True ((Split-Path -Leaf $result.Root) -ceq ('_' + $name)) "Reserved device segment was not protected: $name"
            Assert-True ((Read-DataSafeRepository $result.Root).ComputerName -ceq $name) 'Original device-like name was changed in metadata.'
            Assert-True ([IO.Directory]::Exists($result.LatestRoot)) 'Protected repository cannot be browsed through ordinary Windows paths.'
          }
        }
      }
    }
    Test-Case 'console device names are protected for ordinary Windows browsing' {
      foreach ($name in @('CONIN$', 'CONOUT$', 'conin$.files', 'conout$.files')) {
        $result = Initialize-DataSafeRepository $driveRoot $name ([guid]::NewGuid().ToString('D'))
        Assert-True ((Split-Path -Leaf $result.Root) -ceq ('_' + $name)) "Console device segment was not protected: $name"
        Assert-True ((Read-DataSafeRepository $result.Root).ComputerName -ceq $name) 'Console-like friendly name was changed in metadata.'
      }
    }
    Test-Case 'invalid initializer arguments create no repository' {
      $target = Join-Path $tempRoot 'invalid'
      Ensure-DataSafeDirectory $target
      Assert-Throws { Initialize-DataSafeRepository $target 'PC' '../escape' } 'identity|UUID'
      Assert-Throws { Initialize-DataSafeRepository $target ' ' $id1 } 'name'
      Assert-True (-not (Test-DataSafeDirectory (Join-Path $target 'DataSafe Backups'))) 'Invalid input mutated repository.'
    }
    Test-Case 'corrupt and duplicated repository identities block initialization before creating a new PC' {
      $target = Join-Path $tempRoot 'identity-conflicts'
      Ensure-DataSafeDirectory $target
      $first = Initialize-DataSafeRepository $target 'PC' $id1
      $duplicate = Join-Path (Split-Path -Parent $first.Root) 'Duplicate'
      foreach ($relative in @('Latest Backup','Earlier Versions','.datasafe/manifests','.datasafe/transactions','.datasafe/staging')) {
        Ensure-DataSafeDirectory (Join-Path $duplicate $relative)
      }
      Write-DataSafeAtomicJson (Join-Path $duplicate '.datasafe/repository.json') ([ordered]@{ formatVersion = 2; computerId = $id1; computerName = 'Duplicate' })
      Assert-Throws { Initialize-DataSafeRepository $target 'PC' $id1 } 'duplicat|identity'
      [IO.File]::WriteAllText((ConvertTo-DataSafeExtendedPath (Join-Path $duplicate '.datasafe/repository.json')), '{broken')
      Assert-Throws { Initialize-DataSafeRepository $target 'New PC' $id2 } 'JSON|repository'
      Assert-True (-not (Test-DataSafeDirectory (Join-Path (Split-Path -Parent $first.Root) 'New PC'))) 'Corrupt identity was silently bypassed.'
    }
    Test-Case 'real destination capability query returns actual filesystem' {
      $actual = Get-DataSafeDestinationCapabilities $driveRoot
      $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($driveRoot))
      Assert-True ($actual.FileSystem -eq $drive.DriveFormat) 'Drive filesystem detection disagrees.'
      Assert-True ($actual.TotalBytes -is [long] -and $actual.TotalBytes -eq $drive.TotalSize) 'Drive total capacity missing or incorrect.'
    }
    Test-Case 'atomic JSON write replaces whole documents and create-only preserves winner' {
      $path = Join-Path $tempRoot 'atomic.json'
      Write-DataSafeAtomicJson $path ([ordered]@{ value = 'old' }) -CreateOnly
      Assert-Throws { Write-DataSafeAtomicJson $path ([ordered]@{ value = 'loser' }) -CreateOnly } 'exist|already'
      Assert-True (([IO.File]::ReadAllText((ConvertTo-DataSafeExtendedPath $path)) | ConvertFrom-Json).value -eq 'old') 'Create-only overwrote existing data.'
      Write-DataSafeAtomicJson $path ([ordered]@{ value = 'new' })
      Assert-True (([IO.File]::ReadAllText((ConvertTo-DataSafeExtendedPath $path)) | ConvertFrom-Json).value -eq 'new') 'Replacement failed.'
      $held = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
      try { Assert-Throws { Write-DataSafeAtomicJson $path ([ordered]@{ value = 'blocked' }) } 'process|access|used|sharing' } finally { $held.Dispose() }
      Assert-True (([IO.File]::ReadAllText((ConvertTo-DataSafeExtendedPath $path)) | ConvertFrom-Json).value -eq 'new') 'Failed replacement damaged the old document.'
      Assert-True (@([IO.Directory]::GetFiles((ConvertTo-DataSafeExtendedPath $tempRoot), '*.tmp')).Count -eq 0) 'Temporary files leaked.'
    }
    Test-Case 'safe move refuses overwrite and supports ordinary file and directory renames' {
      $source = Join-Path $tempRoot 'move-source.txt'
      $destination = Join-Path $tempRoot 'move-target.txt'
      [IO.File]::WriteAllText($source, 'original')
      [IO.File]::WriteAllText($destination, 'protected')
      Assert-Throws { Move-DataSafeSameVolume $source $destination } 'exist|already'
      Assert-True ([IO.File]::ReadAllText($destination) -eq 'protected' -and [IO.File]::ReadAllText($source) -eq 'original') 'Rejected move changed data.'
      $newPath = Join-Path $tempRoot 'moved.txt'
      Move-DataSafeSameVolume $source $newPath
      Assert-True ((Test-DataSafeFile $newPath) -and -not (Test-DataSafeFile $source)) 'File did not move.'
      $directory = Join-Path $tempRoot 'move-directory'
      Ensure-DataSafeDirectory $directory
      Move-DataSafeSameVolume $directory (Join-Path $tempRoot 'moved-directory')
      Assert-True (Test-DataSafeDirectory (Join-Path $tempRoot 'moved-directory')) 'Directory did not move.'
    }
    Test-Case 'long paths use safe operations for initialization read and state' {
      $deepRoot = $tempRoot
      1..7 | ForEach-Object { $deepRoot = Join-Path $deepRoot ('deep-segment-' + ('x' * 28)) }
      Ensure-DataSafeDirectory $deepRoot
      $result = Initialize-DataSafeRepository $deepRoot 'Long PC' $id1
      Assert-True ($result.StagingRoot.Length -gt 260 -and (Test-DataSafeDirectory $result.StagingRoot)) 'Long layout not created.'
      Assert-True ((Read-DataSafeRepository $result.Root).ComputerId -eq $id1) 'Long-path read failed.'
      $state = Join-Path $deepRoot 'identity.json'
      Assert-True ((Get-DataSafeComputerId $state) -eq (Get-DataSafeComputerId $state)) 'Long state path is unstable.'
    }
    Test-Case 'junctions are rejected before metadata or external content is mutated' {
      $outside = Join-Path $tempRoot 'junction-target'
      $linkedDrive = Join-Path $tempRoot 'junction-drive'
      Ensure-DataSafeDirectory $outside
      Ensure-DataSafeDirectory $linkedDrive
      $junction = Join-Path $linkedDrive 'DataSafe Backups'
      New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
      try {
        Assert-Throws { Initialize-DataSafeRepository $linkedDrive 'PC' $id1 } 'reparse'
        Assert-Throws { Write-DataSafeAtomicJson (Join-Path $junction 'state.json') @{ value = 1 } } 'reparse'
        Assert-Throws { Get-DataSafeComputerId (Join-Path $junction 'identity.json') } 'reparse'
        Assert-Throws { Move-DataSafeSameVolume $outside (Join-Path $junction 'moved') } 'reparse'
        Assert-True (@([IO.Directory]::GetFileSystemEntries($outside)).Count -eq 0) 'Junction target was changed.'
      } finally { [IO.Directory]::Delete((ConvertTo-DataSafeExtendedPath $junction)) }
    }
    Test-Case 'reparse validation never queries metadata beneath a real junction' {
      $outside = Join-Path $tempRoot 'no-traversal-target'
      $junction = Join-Path $tempRoot 'no-traversal-junction'
      Ensure-DataSafeDirectory $outside
      [IO.File]::WriteAllText((Join-Path $outside 'state.json'), 'outside')
      New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
      $observedPaths = New-Object 'System.Collections.Generic.List[string]'
      $originalConverter = (Get-Item Function:ConvertTo-DataSafeExtendedPath).ScriptBlock
      # Forward every conversion to the real helper. The paths record the
      # actual attribute-query boundary; no filesystem operation is mocked.
      function ConvertTo-DataSafeExtendedPath([string]$Path) {
        $observedPaths.Add($Path)
        & $originalConverter $Path
      }
      try {
        Assert-Throws { Assert-DataSafeNoReparsePath (Join-Path $junction 'state.json') } 'reparse'
        Assert-True ($observedPaths -contains $junction) 'The junction itself was not inspected.'
        Assert-True (@($observedPaths | Where-Object { $_.StartsWith($junction + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) 'An attribute query traversed the junction before rejection.'
      } finally { [IO.Directory]::Delete((& $originalConverter $junction)) }
    }
  } finally { Remove-DataSafeDirectoryTree $tempRoot }
} else { Write-Host 'SKIP: Windows filesystem integration cases (pure capability cases still run).' }

foreach ($name in $passes) { Write-Host "PASS: $name" }
foreach ($failure in $failures) { Write-Host "FAIL: $failure" }
Write-Host "Result: $($passes.Count) passed; $($failures.Count) failed."
if ($failures.Count -gt 0) { exit 1 }
exit 0
