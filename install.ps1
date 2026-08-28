# Раскладывает набор в ~/.claude на рабочей машине.
# Ничего не перезаписывает молча и не трогает settings.json.
# Запуск:  powershell -ExecutionPolicy Bypass -File .\install.ps1

$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'claude'
$dst = Join-Path $env:USERPROFILE '.claude'

if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst | Out-Null }

function Copy-One($relative) {
  $from = Join-Path $src $relative
  $to   = Join-Path $dst $relative
  $dir  = Split-Path $to -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  if (Test-Path $to) {
    $a = (Get-FileHash $from).Hash
    $b = (Get-FileHash $to).Hash
    if ($a -eq $b) { Write-Host "  без изменений  $relative"; return }
    Copy-Item $from "$to.new" -Force
    Write-Host "  УЖЕ ЕСТЬ, положен рядом как .new — слить вручную:  $relative"
    return
  }
  Copy-Item $from $to -Force
  Write-Host "  поставлен       $relative"
}

Write-Host "Правила:"
Copy-One 'rules\agent-hygiene.md'
if (Test-Path (Join-Path $src 'rules\project.md')) {
  Copy-One 'rules\project.md'
} else {
  Write-Host "  нет в наборе    rules\project.md — собирается на месте, а не едет в наборе."
  Write-Host "                  Скажи claude «настройся под проект» — скилл kit-bootstrap."
}

Write-Host "Скиллы:"
Copy-One 'skills\kit-bootstrap\SKILL.md'
Copy-One 'skills\bench-the-fix\SKILL.md'
Copy-One 'skills\schema-from-spec\SKILL.md'
Copy-One 'skills\negative-checks\SKILL.md'

Write-Host "Хуки:"
Copy-One 'hooks\untracked-tests.sh'
Copy-One 'hooks\false-green.sh'

Write-Host ""
Write-Host "Правила и скиллы подхватятся сами при следующем запуске claude."
Write-Host "Хуки надо включить руками: settings.json не трогаю, чтобы не затереть твой."
Write-Host "Вставь содержимое settings-hooks-snippet.json в ~/.claude/settings.json."
Write-Host ""
Write-Host "Отдельно, одной командой, снять ограничение монорепо:"
Write-Host '  git config --global core.excludesFile ~/.gitignore_global'
Write-Host '  echo ".claude/" >> ~/.gitignore_global'
