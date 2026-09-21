#Requires -Version 5.1

[CmdletBinding()]
param (
  [switch]$OpenShell
)

<#
        ┌─────────────────────────┐
────────┤ ANSI Colors & Constants │
────────┴─────────────────────────┘
#>

$ESC = [char]27

$ANSI = @{
  Green  = "$ESC[32m"
  Red    = "$ESC[31m"
  Cyan   = "$ESC[36m"
  Yellow = "$ESC[38;5;208m"
  Reset  = "$ESC[0m"
}

$OKAY = "$($ANSI.Green)OK$($ANSI.Reset):"
$WARN = "$($ANSI.Yellow)Warning$($ANSI.Reset):"
$ERRR = "$($ANSI.Red)Error$($ANSI.Reset):"

$GITHUB = 'https://github.com'
$DEPENDENCIES = "deps"
$DOWNLOADSFOLDER = "downloads"
$PHOBGCCBRANCH = "main"
$TINYUSBCOMMIT = '86ad6e56c1700e85f1c5678607a762cfe3aa2f47' # pinned by pico 2.3.1
$DEPENDENCYNAMES = @{
  PicoSDK      = "pico-sdk"
  CMake        = "cmake"
  Ninja        = "ninja"
  ARMToolchain = "arm-toolchain"
  WinLibs      = "winlibs"
  TinyUSB      = "tinyusb"
}
$REPONAME = "PhobGCC-SW"

$DEBUG = @{
  NoGit = $false
}

<#
        ┌───────────┐
────────┤ Functions │
────────┴───────────┘
#>

function Limit-String32Chars {
  <#
  .SYNOPSIS
    Simple function to limit strings that are too long.
  .PARAMETER InputString
    Input string to limit the length of.
  .PARAMETER MaxLength
    Maximum length of the string before truncation.
    (Defaults to 32 characters)
  #>
  [CmdletBinding()]
  param (
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$InputString,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$MaxLength = 32
  )

  if ($InputString.Length -le $MaxLength) {
    return $InputString
  }
  
  if ($MaxLength -le 3) {
    return $InputString.Substring(0, $MaxLength)
  }

  $avail = $MaxLength - 3

  $lengths = @{
    Prefix = [int]([Math]::Floor($avail * 13.0 / 29.0))
    Suffix = $avail - ([int]([Math]::Floor($avail * 13.0 / 29.0)))
  }

  return (
    $InputString.Substring(0, $lengths.Prefix) + '...' +
    $InputString.Substring($InputString.Length - $lengths.Suffix)
  )
}

function Get-FilenameFromURL {
  <#
  .SYNOPSIS
    Gets the filename expressed in a URL.
  .PARAMETER URL
    URL of the file you want to resolve the filename from.
  #>
  [CmdletBinding()]
  param (
    [Parameter(Mandatory = $true)]
    [string]$URL
  )

  $uri = $null

  $valid = [Uri]::TryCreate(
    $URL.Trim(), [UriKind]::Absolute, [ref]$uri
  ) -or $uri.Scheme -notin @('http', 'https')

  if (-not $valid) {
    throw "$ERRR Expected a proper URL."
  }

  # Decode escaped characters
  $filename = [Uri]::UnescapeDataString(($uri.AbsolutePath -split '/')[-1])
  if ([string]::IsNullOrWhiteSpace($filename) -or
    $filename -in @('.', '..') -or
    $filename.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
    $filename -match '[/\\]' -or $filename -match '[. ]$') {
      throw "$ERRR Filename not detectable in URL '$URL'."
    }
  return $filename
}

enum FileDownloadStatus {
  New
  Active
  Downloading
  Downloaded
  HashFailed
  Completed
  Error
  Exhausted
}

function New-DownloadObject {
  <#
  .SYNOPSIS
    Creates a new DownloadObject for use in this script.
  .PARAMETER URL
    Location of the file to download.
  .PARAMETER SHA256
    SHA256 of the file to check against.
  .PARAMETER DependencyName
    Name of the dependency (for archive expand and environment setup)
  .PARAMETER TestFile
    The filepath to check if the dependency is already installed.
  #>
  [CmdletBinding()]
  param (
    [Parameter(Mandatory = $true)]
    [string]$URL,

    [Parameter(Mandatory = $true)]
    [AllowNull()]
    [AllowEmptyString()]
    [string]$SHA256,

    [Parameter(Mandatory = $true)]
    [string]$DependencyName,

    [Parameter(Mandatory = $true)]
    [string]$TestFile
  )

  $uri = $null

  $valid = [Uri]::TryCreate($URL.Trim(), [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')

  if (-not $valid) {
    throw "$ERRR Expected a URL."
  }

  $filename = Get-FilenameFromURL -URL $URL.Trim()

  function Assert-Hash {
    if (-not [string]::IsNullOrWhiteSpace($SHA256)) {
      return $SHA256.Trim().ToLowerInvariant()
    }
    return $null
  }

  $download = [PSCustomObject]@{
    URL             = $URL.Trim()
    Filename        = $filename
    SHA256          = Assert-Hash
    Status          = [FileDownloadStatus]::New
    DependencyName  = $DependencyName -replace '^(?=(?:CON|PRN|AUX|NUL|(?:COM|LPT)[1-9\u00B9\u00B2\u00B3]) *(?:\.|$)|$)', '_'
    TestFile        = $TestFile
  }

  if (-not (Assert-DownloadObject -File $download)) {
    throw "$ERRR Invalid download file '$filename'."
  }
  return $download
}

function Assert-DownloadObject {
  <#
  .SYNOPSIS
    Checks the validity of a given DownloadObject.
  .PARAMETER File
    The DownloadObject to validate.
  #>
  [CmdletBinding()]
  param (
    [Parameter(Mandatory = $true)]
    [AllowNull()]
    [PSCustomObject]$File
  )

  if ($null -eq $File) {
    return $false
  }

  foreach ($property in @('URL', 'Filename', 'SHA256', 'Status', 'DependencyName', 'TestFile')) {
    if ($null -eq $File.PSObject.Properties[$property]) {
      return $false
    }
  }

  $uri = $null

  $invalid = (-not [Uri]::TryCreate($File.URL.Trim(), [UriKind]::Absolute, [ref]$uri)) -or ($uri.Scheme -notin @('http', 'https'))
  if ($File.URL -isnot [string] -or $invalid) {
    return $false
  }

  $invalid = [string]::IsNullOrWhiteSpace($File.Filename) -or
    $File.Filename -in @('.', '..') -or
    $File.Filename.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
    $File.Filename -match '[/\\]' -or $File.Filename -match '[. ]$'
  if ($File.Filename -isnot [string] -or $invalid) {
    return $false
  }

  $invalid = ($File.SHA256 -isnot [string] -or $File.SHA256 -notmatch '\A[0-9a-fA-F]{64}\z')
  if ($null -ne $File.SHA256 -and $invalid) {
    return $false
  }

  return ($File.Status -is [FileDownloadStatus])
}

function Write-DownloadObjectStatus {
  <#
  .SYNOPSIS
    Writes the status for each DownloadObject in a given array
  .PARAMETER Downloads
    An array of DownloadObjects
  #>
  [CmdletBinding()]
  param (
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [PSCustomObject[]]$Downloads
  )

  foreach ($file in $Downloads) {
    if (-not (Assert-DownloadObject -File $file)) {
      throw "$ERRR Invalid download object."
    }
    $status = $file.Status.ToString().PadRight(12)
    Write-Host "$status $($file.Filename)"
  }
}

function Get-RelativePath {
  <#
  .SYNOPSIS
    Returns a string containing the relative path of a given file compared to the script's path.
  .PARAMETER AbsolutePath
    Absolute path you want to convert to relative 
  #>
  [CmdletBinding()]
  param (
    [Parameter(Mandatory = $true)]
    [string]$AbsolutePath
  )

  Push-Location -LiteralPath $PSScriptRoot -ErrorAction Stop

  try {
    return Resolve-Path -LiteralPath $AbsolutePath -Relative -ErrorAction Stop
  } finally {
    Pop-Location
  }
}

function Copy-FromWeb {
  <#
  .SYNOPSIS
    Copies a file from the web, placing it in a subfolder relative to this script's path.
    Additionally checks its hash, unless the hash field is explicitly marked as null.
    Defaults to "downloads", i.e. '.\downloads'.
  .PARAMETER File
    URL of the file you want to download.
    Must have a valid filename and extension!
  .PARAMETER FolderName
    Target folder/subpath to save the downloaded file to.
    The folder is made automatically if it doesn't exist yet.
    (backslashes are supported)
  #>
  [CmdletBinding()]
  param (
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$File,

    [ValidateNotNullOrEmpty()]
    [string]$FolderName = $DOWNLOADSFOLDER
  )

  if (-not (Assert-DownloadObject -File $File)) {
    throw "$ERRR Invalid download object."
  }

  function Test-DownloadHash {
    param ([string]$Path)
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    $pass = $hash -eq $File.SHA256
    $color = $ANSI.Red
    $label = 'FAIL'
    if ($pass) { $color = $ANSI.Green; $label = 'PASS' }
    $status = "($($color + $label + $ANSI.Reset))"
    Write-Host "Expected:   $($File.SHA256)"
    Write-Host "Calculated: $($hash.ToLowerInvariant()) $status"
    return $pass
  }

  $File.Status = [FileDownloadStatus]::Active

  try {
    # Check for empty folder name
    if ([string]::IsNullOrWhiteSpace($FolderName.Trim())) {
      throw "$ERRR FolderName must not be whitespace."
    }

    # Set up the full folder path
    $folder = Join-Path -Path $PSScriptRoot -ChildPath $FolderName.Trim()

    # Create the directory
    $null = [IO.Directory]::CreateDirectory($folder)

    # Get the filepath of the file to download
    $filepath = Join-Path -Path $folder -ChildPath $File.Filename

    # Determine if we should validate the file's hash
    $validate = $null -ne $File.SHA256
    if ($validate -and (Test-Path -LiteralPath $filepath -PathType Leaf -ErrorAction Stop)) {
      if (Test-DownloadHash -Path $filepath) {
        $File.Status = [FileDownloadStatus]::Completed
        Write-Host "$OKAY Existing '$($File.Filename)' has a matching hash."
        return
      }
      $File.Status = [FileDownloadStatus]::HashFailed
      Write-Host "$WARN Removing '$($File.Filename)' due to hash mismatch."
      Remove-Item -LiteralPath $filepath -ErrorAction Stop
    }

    # Let user know if we are skipping hash checking...
    if (-not $validate) {
      Write-Host "$WARN Skipping hash checks for this file!"
    }

    $total = 3
    $failmsg = ''

    for ($attempt = 1; $attempt -le $total; $attempt++) {
      # Set up a temporary filename until it has been fully downloaded (ex. script interrupted mid-download)
      $partial = "$filepath.$([Guid]::NewGuid().ToString('N')).part"
      try {
        Write-Host "Attempt $attempt/$total..."
        $File.Status = [FileDownloadStatus]::Downloading

        # Download the file
        Write-Host "Downloading '$($File.Filename)' from '$(Limit-String32Chars -InputString $File.URL)'..."
        $null = Invoke-WebRequest -Uri $File.URL -OutFile $partial -UserAgent 'Mozilla/5.0' -UseBasicParsing -ErrorAction Stop
        $File.Status = [FileDownloadStatus]::Downloaded

        # Validate attempts
        if ($validate -and -not (Test-DownloadHash -Path $partial)) {
          $File.Status = [FileDownloadStatus]::HashFailed
          throw "$WARN SHA256 mismatch for '$($File.Filename)'. Reattempting..."
        }

        # Move the now finished download to its intended destination and finish
        Move-Item -LiteralPath $partial -Destination $filepath -Force -ErrorAction Stop
        $File.Status = [FileDownloadStatus]::Completed
        Write-Host "$OKAY '$($File.Filename)' saved to '$(Get-RelativePath -AbsolutePath $filepath)'!"
        return
      } catch {
        # If there was an error that wasn't hash related, mark the file as having errored
        if ($File.Status -ne [FileDownloadStatus]::HashFailed) {
          $File.Status = [FileDownloadStatus]::Error
        }
        $failmsg = $_.Exception.Message
        Write-Host "$WARN Attempt $attempt/$total failed: $failmsg"
      } finally {
        # Cleanup failed attempt in preperation for retry
        if (Test-Path -LiteralPath $partial -ErrorAction Stop) {
          Remove-Item -LiteralPath $partial -ErrorAction Stop
        }
      }
    }

    # All attempts have been made...
    $File.Status = [FileDownloadStatus]::Exhausted
    throw "$ERRR Could not download '$($File.Filename)' after $total attempts. Last error: $failmsg"
  } catch {
    # If there was an error unrelated to exhaustion, mark the file as having errored
    if ($File.Status -ne [FileDownloadStatus]::Exhausted) {
      $File.Status = [FileDownloadStatus]::Error
    }
    throw
  }
}

function Get-GitRepo {
  <#
  .SYNOPSIS
    Clones a GitHub repository, or downloads its fallback branch as a ZIP if Git is unavailable.
  .PARAMETER URL
    URL of the Git repository to clone/download.
  .PARAMETER Branch
    Branch to use for fallback of no usable Git.
    Defaults to 'main'.
  #>
  [CmdletBinding()]
  param (
    [Parameter(Mandatory = $true)]
    [string]$URL,

    # As in the original script, this branch is used for the ZIP fallback only.
    [ValidateNotNullOrEmpty()]
    [string]$Branch = $PHOBGCCBRANCH
  )

  if ($URL.Trim() -notmatch '^https?://github\.com/(?<owner>[A-Za-z0-9-]+)/(?<repo>[A-Za-z0-9_.-]+?)(?:\.git)?/?$') {
    throw "$ERRR Bad GitHub repo URL."
  }

  $owner = $Matches['owner']
  $repo = $Matches['repo']

  if ($repo -in @('.', '..')) {
    throw "$ERRR Bad repo name."
  }

  $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1

  if ($DEBUG.NoGit) {
    # Simulate not having Git if the debug flag is enabled (testing purposes)
    $git = $null
  }

  if ($null -ne $git) {
    $dest = Join-Path -Path $PSScriptRoot -ChildPath $repo

    $gitignore = Join-Path -Path $dest -ChildPath '.gitignore'
    if (Test-Path -LiteralPath $gitignore -PathType Leaf) {
      Write-Host "'$repo' seemingly already cloned, skipping..."
      return
    }

    Write-Host "Cloning '$repo' with Git..."
    & $git.Source clone $URL.Trim() $dest
    if ($LASTEXITCODE -ne 0) {
      throw "$ERRR Git clone failed for '$repo' (exit code $LASTEXITCODE). Destination: '$dest'."
    }
    Write-Host "$OKAY Cloned '$repo'!"
  } else {
    $dest = Join-Path -Path $PSScriptRoot -ChildPath $repo
    $gitignore = Join-Path -Path $dest -ChildPath '.gitignore'
    if (Test-Path -LiteralPath $gitignore -PathType Leaf) {
      Write-Host "'$repo' seemingly already extracted, skipping..."
      return
    }
    Write-Host "$WARN Git unavailable, downloading $repo's branch '$Branch' as ZIP..."
    $file = New-DownloadObject `
      -URL "$GITHUB/$owner/$repo/archive/refs/heads/$([Uri]::EscapeDataString($Branch)).zip" `
      -SHA256 $null `
      -DependencyName $repo `
      -TestFile ".gitignore"
    Copy-FromWeb -File $file
    $archive = Join-Path -Path $PSScriptRoot -ChildPath "$DOWNLOADSFOLDER\$($file.Filename)"
    Write-Host "Extracting '$($file.Filename)'..."
    try {
      # Extract the repository ZIP
      Expand-Archive -Path $archive -DestinationPath (Join-Path -Path $PSScriptRoot -ChildPath $file.DependencyName) -Force

      # Move all the files inside the inner repository folder up a level
      Write-Host "Moving inner repository files up a level..."
      $inner = Join-Path -Path $PSScriptRoot -ChildPath "$repo\$repo-$Branch"
      $innerpaths = Get-ChildItem -Path $inner

      foreach ($path in $innerpaths) {
        Move-Item -LiteralPath $path.FullName -Destination $dest -Force
      }
      Remove-Item -Path $inner # remove empty folder
    } catch {
      throw "$ERRR Unable to expand Git repo archive: $_"
    }
    Write-Host "$OKAY Extracted '$($file.Filename)' into '.\$($file.DependencyName)'!"
  }
}

function Expand-DownloadObjects {
  <#
  .SYNOPSIS
    Expands all archives from a DownloadObject array
  .PARAMETER Files
    DownloadObject array to expand into the project dependencies
  #>
  [CmdletBinding()]
  param (
    [Parameter(Mandatory = $true)]
    [PSCustomObject[]]$Files
  )

  # Set up the full folder path
  $deps = Join-Path -Path $PSScriptRoot -ChildPath $DEPENDENCIES

  # Create the dependencies directory (if it doesn't exist)
  $null = [IO.Directory]::CreateDirectory($deps)

  foreach ($file in $Files) {
    # Verify dependency is a DownloadObject
    if (-not (Assert-DownloadObject -File $file)) {
      throw "$ERRR Invalid download file."
    }
    if (-not ($file.Status -eq [FileDownloadStatus]::Completed)) {
      throw "$ERRR file $($file.Filename) status is not completed! ($($file.Status))"
    }

    # Create dependency folder if it doesn't exist
    $dep = Join-Path -Path $deps -ChildPath $file.DependencyName
    $null = [IO.Directory]::CreateDirectory($dep)

    # Check to see if the dependency already exists
    $testpath = Join-Path -Path $dep -ChildPath $file.TestFile
    if (Test-Path -LiteralPath $testpath -PathType Leaf -ErrorAction Stop) {
      Write-Host "$OKAY Dependency '$($file.DependencyName)' already in-place! Skipping..."
      continue
    }

    $archive = Join-Path -Path $PSScriptRoot -ChildPath "$DOWNLOADSFOLDER\$($file.Filename)"

    Write-Host "Extracting '$($file.Filename)'..."

    if ($archive.EndsWith(".zip")) {
      Expand-Archive -LiteralPath $archive -DestinationPath $dep -Force -ErrorAction Stop
      Write-Host "$OKAY Extracted '$($file.Filename)' into '.\$DEPENDENCIES\$($file.DependencyName)'!"
    } elseif ($archive.EndsWith(".tar.gz")) {
      tar -xf "$archive" -C "$dep" # extract initial .tar.gz
      foreach ($tar in (Get-ChildItem $archive -Filter *.tar -Recurse)) {
        # extract inner .tar
        tar -xf $tar.FullName -C $tar.DirectoryName
        Remove-Item $tar.FullName # delete nested .tar after extraction
        break # there should only ever be one...
      }
      Write-Host "$OKAY Extracted '$($file.Filename)' into '.\$DEPENDENCIES\$($file.DependencyName)'!"
    } else {
      throw "$ERRR Unknown extension type ('$extension')."      
    }
  }
  Write-Host "$OKAY ...Finished extracting all archives!"
}

function Set-PhobGCCEnvironment {
  <#
  .SYNOPSIS
    Sets environmental variables for the current session for PhobGCC development.
  #>

  $root = (Resolve-Path -LiteralPath $PSScriptRoot -ErrorAction Stop).ProviderPath
  $deps = Join-Path $root $DEPENDENCIES

  $sdk = Join-Path $deps "$($DEPENDENCYNAMES.PicoSDK)\pico-sdk-2.3.1"
  $toolchain = Join-Path $deps "$($DEPENDENCYNAMES.ARMToolchain)\xpack-arm-none-eabi-gcc-15.2.1-1.1"
  $tinyusb = Join-Path $deps "$($DEPENDENCYNAMES.TinyUSB)\tinyusb-$TINYUSBCOMMIT"

  # Paths to folders with necessary binaries
  $bins = @{
    ARMToolchain  = Join-Path $toolchain "bin"
    CMake         = Join-Path $deps "$($DEPENDENCYNAMES.CMake)\cmake-4.3.5-windows-x86_64\bin"
    Ninja         = Join-Path $deps "$($DEPENDENCYNAMES.Ninja)"
    Win64Compiler = Join-Path $deps "$($DEPENDENCYNAMES.WinLibs)\mingw64\bin"
  }

  # One last sanity check before setting environmental variables
  $required = @(
    Join-Path $sdk               "pico_sdk_init.cmake"
    Join-Path $sdk               "external\pico_sdk_import.cmake"
    Join-Path $bins.ARMToolchain "arm-none-eabi-gcc.exe"
    Join-Path $bins.ARMToolchain "arm-none-eabi-g++.exe"
    Join-Path $bins.CMake        "cmake.exe"
    Join-Path $bins.Ninja        "ninja.exe"
    Join-Path $bins.Win64Compiler "gcc.exe"
    Join-Path $bins.Win64Compiler "g++.exe"
    Join-Path $tinyusb           "src\tusb.c"
    Join-Path $tinyusb           "hw\bsp\family_support.cmake"
  )

  foreach ($file in $required) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
      throw "$ERRR Required dependency is missing: '$(Split-Path $file -Leaf)'"
    }
  }

  # Place the dev environment tools at the front of PATH, while checking for duplicates
  # (and skipping them, in case the user has already done this for some reason)
  $tools = @($bins.CMake, $bins.Ninja, $bins.Win64Compiler, $bins.ARMToolchain)

  $remaining = @(
    $env:PATH -split ';' | Where-Object {
      -not [string]::IsNullOrWhiteSpace($_) -and $_ -notin $tools
    }
  )

  $env:PATH = ($tools + $remaining) -join ';'

  # CMake wants forward slashes, thanks Windows
  $env:PICO_SDK_PATH = $sdk -replace '\\', '/'
  $env:PICO_TOOLCHAIN_PATH = $toolchain -replace '\\', '/'
  $env:PICO_TINYUSB_PATH = $tinyusb -replace '\\', '/'
  $env:PICO_PLATFORM = 'rp2040'
  $env:CMAKE_GENERATOR = 'Ninja'
  # Win64 compiler tools for pioasm and picotool
  $env:CC = (Join-Path $bins.Win64Compiler 'gcc.exe') -replace '\\', '/'
  $env:CXX = (Join-Path $bins.Win64Compiler 'g++.exe') -replace '\\', '/'

  Write-Host "-----------------------------------------------------------------------"
  Write-Host "$OKAY PhobGCC dev environment successfully configured for this session!"
  Write-Host ""
  Write-Host "  $($ANSI.Cyan)SDK$($ANSI.Reset):       $env:PICO_SDK_PATH"
  Write-Host "  $($ANSI.Cyan)TinyUSB$($ANSI.Reset):   $env:PICO_TINYUSB_PATH"
  Write-Host "  $($ANSI.Cyan)Toolchain$($ANSI.Reset): $env:PICO_TOOLCHAIN_PATH"
  Write-Host "  $($ANSI.Cyan)Platform$($ANSI.Reset):  $env:PICO_PLATFORM"
  Write-Host "  $($ANSI.Cyan)Generator$($ANSI.Reset): $env:CMAKE_GENERATOR"
  Write-Host "  $($ANSI.Cyan)Win64 C$($ANSI.Reset):   $env:CC"
  Write-Host "  $($ANSI.Cyan)Win64 C++$($ANSI.Reset): $env:CXX"
}

function Invoke-DependencySetup {
  <#
  .SYNOPSIS
    Acquires all necessary dependencies for PhobGCC firmware development.
  #>

  # Get latest PhobGCC Software Codebase
  Get-GitRepo -URL "https://github.com/PhobGCC/$REPONAME.git"

  # DownloadObject array of dependencies
  $downloads = @(
    # PicoSDK 2.3.1
    New-DownloadObject `
      -URL "$GITHUB/raspberrypi/pico-sdk/releases/download/2.3.1/pico-sdk-2.3.1.tar.gz" `
      -SHA256 "4cd9f1f36feb34b6853ca866b5e0d977e3d344a361b9b7c94ae383693303591a" `
      -DependencyName $DEPENDENCYNAMES.PicoSDK `
      -TestFile "pico-sdk-2.3.1\src\host.cmake"
    # CMake 4.3.5
    New-DownloadObject `
      -URL "$GITHUB/Kitware/CMake/releases/download/v4.3.5/cmake-4.3.5-windows-x86_64.zip" `
      -SHA256 "c05a60d22d5df22d75a72ae9b6628ef5f20daee4f4ba380920e1fbbeaf244fc1" `
      -DependencyName $DEPENDENCYNAMES.CMake `
      -TestFile "cmake-4.3.5-windows-x86_64\bin\cmake.exe"
    # Ninja 1.13.2
    New-DownloadObject `
      -URL "$GITHUB/ninja-build/ninja/releases/download/v1.13.2/ninja-win.zip" `
      -SHA256 "07fc8261b42b20e71d1720b39068c2e14ffcee6396b76fb7a795fb460b78dc65" `
      -DependencyName $DEPENDENCYNAMES.Ninja `
      -TestFile "ninja.exe"
    # GNU ARM Build Toolchain 15.2.1-1.1
    New-DownloadObject `
      -URL "$GITHUB/xpack-dev-tools/arm-none-eabi-gcc-xpack/releases/download/v15.2.1-1.1/xpack-arm-none-eabi-gcc-15.2.1-1.1-win32-x64.zip" `
      -SHA256 "bae6a3d1667697ce750c3b13d6d26d80973ecedc2cc87bf04869e83447fd93ea" `
      -DependencyName $DEPENDENCYNAMES.ARMToolchain `
      -TestFile "xpack-arm-none-eabi-gcc-15.2.1-1.1\bin\arm-none-eabi-gcc.exe"
    # WinLibs GCC 16.2.0
    New-DownloadObject `
      -URL "$GITHUB/brechtsanders/winlibs_mingw/releases/download/16.2.0posix-14.0.0-ucrt-r1/winlibs-x86_64-posix-seh-gcc-16.2.0-mingw-w64ucrt-14.0.0-r1.zip" `
      -SHA256 "c1f52294597c0b73786b2a78eb5d176d89226d2f21875eab75e783a8b1cefcc4" `
      -DependencyName $DEPENDENCYNAMES.WinLibs `
      -TestFile "mingw64\bin\gcc.exe"
    # TinyUSB (pinned to pico 2.3.1)
    New-DownloadObject `
      -URL "$GITHUB/hathach/tinyusb/archive/$TINYUSBCOMMIT.zip" `
      -SHA256 "3011c90c128988012b553e5d2f0a90bc0b64046591c964bc1f9f6659edcd7e4b" `
      -DependencyName $DEPENDENCYNAMES.TinyUSB `
      -TestFile "tinyusb-$TINYUSBCOMMIT\src\tusb.c"
  )

  $failures = @() # track failures

  foreach ($file in $downloads) {
    try {
      Copy-FromWeb -File $file
    } catch {
      $failures += $file.Filename
      Write-Host "$ERRR $($_.Exception.Message)"
      Write-DownloadObjectStatus -Downloads $downloads
    }
  }
  if ($failures.Count -gt 0) {
    throw "$ERRR Failed to download: $($failures -join ', ')."
  }

  Expand-DownloadObjects -Files $downloads
  Set-PhobGCCEnvironment
}

<#
        ┌──────┐
────────┤ Main │
────────┴──────┘
#>

# If this script was started normally, run dependency download and environment setup
if ($MyInvocation.InvocationName -ne '.') {
  Invoke-DependencySetup
  Write-Host ""

  if ($OpenShell) {
    # Inherit the environment configuration if started by a terminal
    Push-Location -LiteralPath "$PSScriptRoot\$REPONAME" -ErrorAction Stop
    try {
      Write-Host "  #########################################################"
      Write-Host "  # PhobGCC command prompt activated. Type exit to leave. #"
      Write-Host "  #########################################################"
      Write-Host ""
      & "..\phobgcc-dev-env.bat" buildask
      & $env:ComSpec /d /k
    } finally {
      Pop-Location
    }
  }
}
