$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

& git -C $repositoryRoot rev-parse --show-toplevel *> $null
if ($LASTEXITCODE -ne 0) {
    throw "This script must be run inside a Git repository."
}

& git -C $repositoryRoot config core.hooksPath .githooks
if ($LASTEXITCODE -ne 0) {
    throw "Could not configure Git's hooks path."
}

$hooksPath = & git -C $repositoryRoot config --get core.hooksPath
Write-Host "Git hooks enabled: $hooksPath"
Write-Host "The prerender pre-commit hook will run when relevant page files are staged."
