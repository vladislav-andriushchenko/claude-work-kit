# Раскладывает набор в ~/.claude на рабочей машине.
# Ничего не перезаписывает молча и не трогает settings.json.
# Запуск:  powershell -ExecutionPolicy Bypass -File .\install.ps1

$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'claude'
$dst = Join-Path $env:USERPROFILE '.claude'

# Список один на все проходы: по нему же идёт предполётная проверка.
$rules   = @('rules\agent-hygiene.md', 'rules\data-boundary.md', 'rules\incident-log.md')
$skills  = @('skills\kit-bootstrap\SKILL.md', 'skills\bench-the-fix\SKILL.md',
             'skills\schema-from-spec\SKILL.md', 'skills\negative-checks\SKILL.md')
$hooks   = @('hooks\untracked-tests.sh', 'hooks\false-green.sh')
$journal = @('incidents.md')

$failed = 0

# Пути везде через -LiteralPath. С обычным -Path квадратная скобка в имени
# каталога («claude-work-kit [v2]») считается шаблоном: Get-FileHash молча
# возвращает $null, а Copy-Item так же молча ничего не копирует и выходит
# успехом. Установщик при этом печатает «поставлен» — ровно то ложное зелёное,
# которое ловит хук false-green из этого же набора.
function Copy-One($relative) {
  $from = Join-Path $src $relative
  $to   = Join-Path $dst $relative
  $dir  = Split-Path $to -Parent
  try {
    [void][IO.Directory]::CreateDirectory($dir)

    if (Test-Path -LiteralPath $to) {
      $a = (Get-FileHash -LiteralPath $from).Hash
      $b = (Get-FileHash -LiteralPath $to).Hash
      if ($a -eq $b) { Write-Host "  без изменений  $relative"; return }

      # Имя .new одно на файл, поэтому занято оно ровно один раз. Копия туда
      # с -Force молча затирает слияние, начатое человеком, и печатает при
      # этом ту же строку, что и при обычном создании файла.
      $side = "$to.new"
      if (Test-Path -LiteralPath $side) {
        if ((Get-FileHash -LiteralPath $side).Hash -eq $a) {
          Write-Host "  .new уже лежит  $relative"
          return
        }
        Write-Host "  РЯДОМ ЧУЖОЙ .new, НЕ ТРОГАЮ — слить и удалить его:  $relative"
        return
      }

      Copy-Item -LiteralPath $from -Destination $side
      Write-Host "  УЖЕ ЕСТЬ, положен рядом как .new — слить вручную:  $relative"
      return
    }

    Copy-Item -LiteralPath $from -Destination $to
    Write-Host "  поставлен       $relative"
  }
  catch {
    # Один занятый файл не должен уносить весь прогон: журнал и подсказки
    # идут последними, и до них тогда никто не доходит. Синхронизация или
    # бэкап держат файл эксклюзивно — Get-FileHash падает терминирующей
    # ошибкой, потому что $ErrorActionPreference здесь Stop.
    $script:failed++
    Write-Host "  НЕ СМОГ         $relative — $($_.Exception.Message)"
  }
}

# Предполёт: неполный набор ловится до того, как что-то поставлено наполовину.
$missing = @()
foreach ($r in ($rules + $skills + $hooks + $journal)) {
  if (-not (Test-Path -LiteralPath (Join-Path $src $r))) { $missing += $r }
}
if ($missing.Count -gt 0) {
  Write-Host "Набор неполон, не ставлю ничего. Не хватает:"
  foreach ($m in $missing) { Write-Host "  $m" }
  exit 1
}

[void][IO.Directory]::CreateDirectory($dst)

Write-Host "Правила:"
foreach ($r in $rules) { Copy-One $r }
if (Test-Path -LiteralPath (Join-Path $src 'rules\project.md')) {
  Copy-One 'rules\project.md'
} else {
  Write-Host "  нет в наборе    rules\project.md — собирается на месте, а не едет в наборе."
  Write-Host "                  Скажи claude «настройся под проект» — скилл kit-bootstrap."
}

Write-Host "Скиллы:"
foreach ($r in $skills) { Copy-One $r }

Write-Host "Хуки:"
foreach ($r in $hooks) { Copy-One $r }

# Правило incident-log велит писать в этот файл. Без заготовки адресата нет:
# агенту сказано «оформляй сразу», а класть некуда.
Write-Host "Журнал:"
foreach ($r in $journal) { Copy-One $r }

Write-Host ""
Write-Host "Правила и скиллы подхватятся сами при следующем запуске claude."
Write-Host "Хуки надо включить руками: settings.json не трогаю, чтобы не затереть твой."
Write-Host "Вставь содержимое settings-hooks-snippet.json в ~/.claude/settings.json."
Write-Host ""
Write-Host "Отдельно, одной командой, снять ограничение монорепо:"
Write-Host '  git config --global core.excludesFile ~/.gitignore_global'
Write-Host '  echo ".claude/" >> ~/.gitignore_global'

if ($failed -gt 0) {
  Write-Host ""
  Write-Host "НЕ УСТАНОВЛЕНО ФАЙЛОВ: $failed. Смотри строки «НЕ СМОГ» выше."
  exit 1
}
