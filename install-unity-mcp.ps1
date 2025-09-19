<#
.SYNOPSIS
    Installs and configures the Unity MCP Python server and Cursor MCP client integration on Windows 11.

.DESCRIPTION
    This script automates the Windows setup steps described in the repository README for running the Unity MCP server and
    connecting it to the Cursor editor. It will:
      * Ensure Python 3.12+ and the `uv` toolchain manager are installed (via winget when needed).
      * Copy the packaged Unity MCP server from this repository into %LOCALAPPDATA%\Programs\UnityMCP\UnityMcpServer.
      * Pre-install the server's Python dependencies with `uv sync`.
      * Configure Cursor's global mcp.json to launch the server via uv.

    Run the script from the root of the repository using Windows PowerShell 5.1 or PowerShell 7:
        powershell -ExecutionPolicy Bypass -File .\install-unity-mcp.ps1

    After the script finishes, open your Unity project and install the package using the Git URL from the README, then use
    Window > MCP for Unity > Auto-Setup to finalise the in-Editor configuration.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'This installer only supports Windows.'
}

function Invoke-WingetInstall {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string[]]$AdditionalArgs
    )

    $winget = Get-Command 'winget' -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'winget was not found on PATH. Install winget or install the prerequisites manually.'
    }

    $args = @('install', '--id', $Id, '-e', '--accept-package-agreements', '--accept-source-agreements')
    if ($AdditionalArgs) {
        $args += $AdditionalArgs
    }

    Write-Host "Running: winget $($args -join ' ')"
    $process = Start-Process -FilePath $winget.Source -ArgumentList $args -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "winget install for $Id failed with exit code $($process.ExitCode)."
    }
}

function Test-Python312OrNewer {
    $pyLauncher = Get-Command 'py' -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        & $pyLauncher.Source '-3.12' '--version' *> $null
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
    }

    $python = Get-Command 'python' -ErrorAction SilentlyContinue
    if ($python) {
        $output = & $python.Source '--version' 2>&1
        if ($LASTEXITCODE -eq 0 -and $output -match 'Python\s+(\d+)\.(\d+)') {
            $major = [int]$Matches[1]
            $minor = [int]$Matches[2]
            if ($major -gt 3 -or ($major -eq 3 -and $minor -ge 12)) {
                return $true
            }
        }
    }

    return $false
}

function Ensure-Python312 {
    if (Test-Python312OrNewer) {
        Write-Host 'Python 3.12+ already installed.'
        return
    }

    Write-Host 'Python 3.12 not found. Installing via winget...'
    Invoke-WingetInstall -Id 'Python.Python.3.12'

    if (-not (Test-Python312OrNewer)) {
        throw 'Python 3.12 installation could not be verified. Please install it manually.'
    }
}

function Get-UvCandidatePaths {
    $paths = @()
    if ($Env:LOCALAPPDATA) {
        $paths += Join-Path $Env:LOCALAPPDATA 'Microsoft\WinGet\Links\uv.exe'
    }
    $paths += 'C:\Program Files\WinGet\Links\uv.exe'
    return $paths
}

function Get-UvExecutable {
    foreach ($path in Get-UvCandidatePaths) {
        if (Test-Path $path) {
            return $path
        }
    }

    $uvCommand = Get-Command 'uv' -ErrorAction SilentlyContinue
    if ($uvCommand) {
        return $uvCommand.Source
    }

    return $null
}

function Ensure-Uv {
    $uvExe = Get-UvExecutable
    if ($uvExe) {
        Write-Host "uv found at: $uvExe"
        return $uvExe
    }

    Write-Host 'uv not found. Installing via winget...'
    Invoke-WingetInstall -Id 'astral-sh.uv'

    $uvExe = Get-UvExecutable
    if (-not $uvExe) {
        throw 'uv installation could not be verified. Please install it manually.'
    }

    Write-Host "uv installed at: $uvExe"
    return $uvExe
}

function ConvertTo-OrderedHashtable {
    param(
        [Parameter(ValueFromPipeline = $true)]$InputObject
    )
    process {
        if ($null -eq $InputObject) { return $null }

        if ($InputObject -is [System.Collections.IDictionary]) {
            $ordered = [ordered]@{}
            foreach ($key in $InputObject.Keys) {
                $ordered[$key] = ConvertTo-OrderedHashtable $InputObject[$key]
            }
            return $ordered
        }

        if ($InputObject -is [System.Management.Automation.PSObject]) {
            $ordered = [ordered]@{}
            foreach ($prop in $InputObject.PSObject.Properties) {
                $ordered[$prop.Name] = ConvertTo-OrderedHashtable $prop.Value
            }
            return $ordered
        }

        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $list = @()
            foreach ($item in $InputObject) {
                $list += ,(ConvertTo-OrderedHashtable $item)
            }
            return $list
        }

        return $InputObject
    }
}

function Update-CursorConfig {
    param(
        [Parameter(Mandatory = $true)][string]$UvCommand,
        [Parameter(Mandatory = $true)][string]$ServerPath
    )

    $cursorDir = Join-Path $Env:USERPROFILE '.cursor'
    if (-not (Test-Path $cursorDir)) {
        New-Item -ItemType Directory -Path $cursorDir | Out-Null
    }

    $configPath = Join-Path $cursorDir 'mcp.json'
    $configData = [ordered]@{}

    if (Test-Path $configPath) {
        $raw = Get-Content -Path $configPath -Raw -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            try {
                $configData = ConvertTo-OrderedHashtable (ConvertFrom-Json $raw)
            } catch {
                throw "Unable to parse existing Cursor config at $configPath. Please fix or remove the file and re-run the script."
            }
        }
    }

    if (-not $configData.Contains('mcpServers')) {
        $configData['mcpServers'] = [ordered]@{}
    }

    $servers = $configData['mcpServers']
    if ($servers -isnot [System.Collections.IDictionary]) {
        $servers = [ordered]@{}
        $configData['mcpServers'] = $servers
    }

    $servers['unityMCP'] = [ordered]@{
        command = $UvCommand
        args    = @('--directory', $ServerPath, 'run', 'server.py')
    }

    $json = $configData | ConvertTo-Json -Depth 20
    Set-Content -Path $configPath -Value $json -Encoding UTF8
    Write-Host "Updated Cursor MCP configuration at: $configPath"
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$bridgePath = Join-Path $scriptRoot 'UnityMcpBridge'
$serverSource = Join-Path (Join-Path $bridgePath 'UnityMcpServer~') 'src'
if (-not (Test-Path $serverSource)) {
    throw "Unity MCP server sources not found at $serverSource. Run this script from the repository root."
}

$installBase = Join-Path $Env:LOCALAPPDATA 'Programs\UnityMCP'
$serverInstallRoot = Join-Path $installBase 'UnityMcpServer'
$serverInstallPath = Join-Path $serverInstallRoot 'src'

Write-Host '--- Ensuring prerequisites ---'
Ensure-Python312
$uvExecutable = Ensure-Uv

Write-Host "--- Deploying Unity MCP server to $serverInstallRoot ---"
if (-not (Test-Path $installBase)) {
    New-Item -ItemType Directory -Path $installBase | Out-Null
}
if (Test-Path $serverInstallRoot) {
    Write-Host 'Removing existing server installation...'
    Remove-Item -Path $serverInstallRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $serverInstallRoot | Out-Null
Copy-Item -Path $serverSource -Destination $serverInstallRoot -Recurse -Force

Write-Host '--- Installing Python dependencies with uv sync ---'
$uvArgs = @('--directory', $serverInstallPath, 'sync', '--locked')
$syncProcess = Start-Process -FilePath $uvExecutable -ArgumentList $uvArgs -Wait -PassThru
if ($syncProcess.ExitCode -ne 0) {
    throw "uv sync failed with exit code $($syncProcess.ExitCode)."
}

Write-Host '--- Updating Cursor MCP configuration ---'
Update-CursorConfig -UvCommand $uvExecutable -ServerPath $serverInstallPath

Write-Host "\nSetup complete!"
Write-Host 'Next steps:'
Write-Host '  1. In your Unity project, install the package via Window > Package Manager > Add package from git URL:'
Write-Host '       https://github.com/CoplayDev/unity-mcp.git?path=/UnityMcpBridge'
Write-Host '  2. In Unity, open Window > MCP for Unity and click Auto-Setup to verify the connection.'
Write-Host '  3. Restart Cursor so it reloads the updated MCP configuration.'
