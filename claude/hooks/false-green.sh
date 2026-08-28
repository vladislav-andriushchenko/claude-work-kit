#!/bin/bash
# Возврат ложно-зелёного пайплайна. Пайплайн уже был ложно-зелёным один раз,
# и починка выносилась отдельным изменением — значит конфигурация к этому склонна.
#
# Гейт на коммит: в сомнении запрещать. Ложный запрет стоит одной команды.
# Сомнение относится к находке («правда ли это подавление»), а не к сантехнике.
# Если не удалось понять, что за команда, — это не сомнение, а незнание,
# и тогда хук молчит: блокировать всё подряд означает запереть агента без выхода.
set -u

# Всегда подозрительно, в любом файле.
PAT_ANY='ignoreFailures[[:space:]]*=[[:space:]]*true|continueOnError[[:space:]]*:[[:space:]]*true|allow_failure[[:space:]]*:[[:space:]]*true'
# Подозрительно только в конфигурации и скриптах CI: в обычном шелле `|| true` — норма.
PAT_CI='\|\|[[:space:]]*true'
IS_CI='(^|/)(\.gitlab-ci|\.travis|azure-pipelines)|(^|/)(ci-scripts|ci-configs|\.github|\.circleci|scripts/ci)/'

# `commit` как подкоманда git, а не любое вхождение слова.
# Иначе `git log --grep=commit` и `git diff # что коммитить` блокируются наравне с коммитом.
IS_COMMIT='git([[:space:]]+-[cC][[:space:]]*[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)'

scan() {
  local found=""
  local files
  files=$(git diff --cached --name-only 2>/dev/null) || return 0
  [ -z "$files" ] && return 0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    local pat="$PAT_ANY"
    if printf '%s' "$f" | grep -qE "$IS_CI"; then
      pat="$PAT_ANY|$PAT_CI"
    fi
    local hit
    # Склеиваем перенос строки: `run_tests || \` + `true` — то же подавление,
    # что и в одну строку, но однострочный поиск его не видит.
    hit=$(git diff --cached -U0 -- "$f" 2>/dev/null \
          | grep -E '^\+' \
          | sed -e :a -e '/\\$/N; s/\\\n+//; ta' \
          | grep -E "$pat" || true)
    [ -n "$hit" ] && found="$found$f: $hit"$'\n'
  done <<< "$files"
  printf '%s' "$found"
}

selftest() {
  local t fail=0
  t=$(mktemp -d) || exit 1
  cd "$t" || exit 1
  git init -q . && git config user.email t@t && git config user.name t
  mkdir -p ci-scripts src

  check() { # имя; ожидание пусто|непусто
    local got; got=$(scan)
    if [ "$2" = "пусто" ] && [ -n "$got" ]; then echo "ПРОВАЛ: $1"; fail=1; fi
    if [ "$2" = "непусто" ] && [ -z "$got" ]; then echo "ПРОВАЛ: $1"; fail=1; fi
  }
  cmd() { printf '%s' "$1" | grep -qE "$IS_COMMIT"; }

  printf 'HIT=$(grep foo bar || true)\n' > src/normal.sh
  git add src/normal.sh
  check "'|| true' в обычном скрипте не должен ловиться" пусто

  printf 'run_tests || true\n' > ci-scripts/check.sh
  git add ci-scripts/check.sh
  check "'|| true' в ci-scripts должен ловиться" непусто

  git rm -q --cached ci-scripts/check.sh
  { echo 'run_tests || \'; echo '  true'; } > ci-scripts/check.sh
  git add ci-scripts/check.sh
  check "'|| \\' с переносом строки должен ловиться" непусто

  git rm -q --cached ci-scripts/check.sh
  printf 'ignoreFailures = true\n' > build.gradle.kts
  git add build.gradle.kts
  check "ignoreFailures должен ловиться в любом файле" непусто

  cmd 'git commit -m x'                    || { echo "ПРОВАЛ: коммит не опознан"; fail=1; }
  cmd 'cd foo && git commit'               || { echo "ПРОВАЛ: коммит после && не опознан"; fail=1; }
  cmd 'git -c user.name=x commit -m y'     || { echo "ПРОВАЛ: коммит с -c не опознан"; fail=1; }
  cmd 'git log --grep=commit'              && { echo "ПРОВАЛ: git log принят за коммит"; fail=1; }
  cmd 'git diff --stat # what to commit'   && { echo "ПРОВАЛ: комментарий принят за коммит"; fail=1; }

  cd / && rm -rf "$t"
  [ "$fail" = 0 ] && echo "selftest ok" || exit 1
}

[ "${1:-}" = "--selftest" ] && { selftest; exit 0; }

# Хук висит на всех вызовах Bash, потому что матчер в settings.json умеет только имя
# инструмента. Отделяем коммит здесь: без этого блокируется любая команда, включая ту,
# которой изменение вынимают из индекса, и выхода из блокировки не остаётся.
PAYLOAD=$(timeout 2 cat 2>/dev/null || true)
printf '%s' "$PAYLOAD" | grep -qE "$IS_COMMIT" || exit 0

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

FOUND=$(scan)
[ -z "$FOUND" ] && exit 0

echo "В индексе появилось подавление падений — пайплайн станет зелёным при упавших тестах:" >&2
printf '%s\n' "$FOUND" >&2
echo "Коммит не выполнен. Останови работу и покажи это владельцу репозитория." >&2
echo "Если подавление осознанное, коммит делается человеком из своего терминала:" >&2
echo "хук отсекает только вызовы агента и на ручной коммит не действует." >&2
exit 2
