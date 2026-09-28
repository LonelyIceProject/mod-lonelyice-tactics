# Install the BotTactics ("Отряд" / Party) addon into the game client.
# Copies client\addons\BotTactics (the .toc, every .lua / .xml) to Interface\AddOns\BotTactics and removes files
# there that no longer exist in the source. SavedVariables (WTF\...\BotTacticsDB) are not touched.
#
#   .\tools\install_addon.ps1 -Client 'D:\WoW 3.3.5a'           # install
#   .\tools\install_addon.ps1 -Client 'D:\WoW 3.3.5a' -WhatIf   # show what would change
#   -LuaJit <path to luajit.exe> checks every .lua before installing (skipped when not given)
#
# The 3.3.5 client reads the .toc file list only at start: after adding/removing files restart the game;
# a changed .lua is picked up by /reload. Before installing it checks every .lua with luajit -bl.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Client,
    [string]$LuaJit = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$src = Join-Path $root 'client\addons\BotTactics'
$dst = Join-Path $Client 'Interface\AddOns\BotTactics'
$luajit = $LuaJit

if (-not (Test-Path (Join-Path $src 'BotTactics.toc'))) { throw "addon source not found: $src" }
if (-not (Test-Path (Join-Path $Client 'Interface\AddOns'))) { throw "client AddOns folder not found under: $Client" }

$files = @(Get-ChildItem $src -File | Where-Object { $_.Extension -in '.toc', '.lua', '.xml' })

# every file the .toc lists must exist in the source
$toc = Get-Content (Join-Path $src 'BotTactics.toc') -Encoding UTF8 |
    Where-Object { $_ -match '^\s*[^#\s].*\.(lua|xml)\s*$' } | ForEach-Object { $_.Trim() }
$missing = @($toc | Where-Object { -not (Test-Path (Join-Path $src $_)) })
if ($missing.Count) { throw "files listed in BotTactics.toc are missing: $($missing -join ', ')" }

# syntax check (party-window-spec 10.1)
if ($luajit -and (Test-Path $luajit)) {
    Push-Location (Split-Path $luajit)
    try {
        foreach ($f in $files | Where-Object Extension -eq '.lua') {
            $out = & $luajit -bl $f.FullName 2>&1
            if ($LASTEXITCODE -ne 0) { throw "syntax error in $($f.Name): $($out | Select-Object -First 1)" }
        }
    } finally { Pop-Location }
} else {
    Write-Warning "luajit not found ($luajit): syntax check skipped"
}

if (Get-Process Wow -ErrorAction SilentlyContinue) {
    Write-Warning 'WoW is running: restart the game (new files) or /reload (changed files) after installing.'
}

if (-not (Test-Path $dst)) {
    if ($PSCmdlet.ShouldProcess($dst, 'create folder')) { New-Item -ItemType Directory -Path $dst | Out-Null }
}

$copied = 0
foreach ($f in $files) {
    $target = Join-Path $dst $f.Name
    $same = (Test-Path $target) -and ((Get-FileHash $target).Hash -eq (Get-FileHash $f.FullName).Hash)
    if (-not $same -and $PSCmdlet.ShouldProcess($target, 'copy')) {
        Copy-Item $f.FullName $target -Force
        $copied++
    }
}

# drop installed files that the source no longer has (only addon file types; folders are left alone)
$removed = 0
if (Test-Path $dst) {
    $names = $files | ForEach-Object Name
    foreach ($old in Get-ChildItem $dst -File | Where-Object { $_.Extension -in '.toc', '.lua', '.xml' -and $_.Name -notin $names }) {
        if ($PSCmdlet.ShouldProcess($old.FullName, 'remove stale file')) {
            Remove-Item $old.FullName -Confirm:$false
            $removed++
        }
    }
}

Write-Host "BotTactics -> $dst : $copied copied, $removed removed, $($files.Count - $copied) unchanged."
