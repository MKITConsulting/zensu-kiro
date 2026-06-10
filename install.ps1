# zensu-kiro Windows installer wrapper. Kiro CLI is Windows-native, but the
# zensu hooks are bash scripts — this wrapper locates GIT BASH (never WSL's
# System32 bash, which would install into the WSL filesystem invisible to the
# Windows Kiro CLI) and delegates to install.sh with all arguments.
$ErrorActionPreference = "Stop"

$candidates = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "$env:LocalAppData\Programs\Git\bin\bash.exe"
)

# PATH lookup only as a last resort, excluding WSL's System32/Sysnative bash.
$pathBash = Get-Command bash.exe -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
if ($pathBash -and ($pathBash -notmatch '\\Windows\\(System32|Sysnative)\\')) {
    $candidates += $pathBash
}

$bash = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if (-not $bash) {
    Write-Error "Git Bash not found. Kiro CLI runs natively on Windows, but the zensu hooks are bash scripts — install Git for Windows (https://gitforwindows.org/) and re-run install.ps1. (WSL's \Windows\System32\bash.exe is deliberately not used: it would install into the WSL filesystem.)"
    exit 1
}

$installSh = Join-Path $PSScriptRoot "install.sh"
& $bash $installSh @args
exit $LASTEXITCODE
