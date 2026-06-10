# zensu-kiro Windows installer wrapper. Kiro CLI is Windows-native, but the
# zensu hooks are bash scripts — this wrapper locates Git Bash and delegates to
# install.sh with all arguments. Without Git Bash the skills/agents/MCP pieces
# could be copied by hand, but the hook tier (gates, witness, stop enforcement)
# needs bash, so we require it.
$ErrorActionPreference = "Stop"

$candidates = @(
    (Get-Command bash.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
    "$env:ProgramFiles\Git\bin\bash.exe",
    "$env:ProgramFiles(x86)\Git\bin\bash.exe",
    "$env:LocalAppData\Programs\Git\bin\bash.exe"
) | Where-Object { $_ -and (Test-Path $_) }

if (-not $candidates) {
    Write-Error "Git Bash not found. Kiro CLI runs natively on Windows, but the zensu hooks are bash scripts — install Git for Windows (https://gitforwindows.org/) and re-run install.ps1."
    exit 1
}

$bash = $candidates | Select-Object -First 1
$installSh = Join-Path $PSScriptRoot "install.sh"
& $bash $installSh @args
exit $LASTEXITCODE
