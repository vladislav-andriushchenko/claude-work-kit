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
# `continue-on-error` через дефис — это GitHub Actions, `continueOnError` — Azure.
# Пропустить первый значит не видеть самый распространённый CI в мире.
PAT_ANY='ignoreFailures[[:space:]]*=[[:space:]]*true|continueOnError[[:space:]]*:[[:space:]]*true|continue-on-error[[:space:]]*:[[:space:]]*true|allow_failure[[:space:]]*:[[:space:]]*true'
# Подозрительно только в конфигурации и скриптах CI: в обычном шелле `|| true` — норма.
PAT_CI='\|\|[[:space:]]*true'
IS_CI='(^|/)(\.gitlab-ci|\.travis|azure-pipelines|Jenkinsfile)|(^|/)(ci-scripts|ci-configs|\.github|\.circleci|scripts/ci)/'

# `commit` как первый неключевой аргумент git, а не любое вхождение слова.
# Слева обязателен разделитель команд: иначе `echo git commit` блокируется как коммит.
# Между `git` и `commit` допускаются флаги и по одному значению на флаг, поэтому
# `git -c user.name=X commit` и `git --no-pager commit` опознаются, а
# `git log --grep=commit` и `git diff --stat # what to commit` — нет: у них
# первый же аргумент не флаг.
IS_COMMIT='(^|[;&|(])[[:space:]]*git([[:space:]]+-[^[:space:]]*([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+commit([[:space:]]|$)'

# Кавычки скрывают пробелы внутри значений флагов. Схлопываем их до одного токена
# до разбора: без этого `git -c user.name="Jane Doe" commit` не опознаётся.
strip_quotes() {
  sed -e "s/'[^']*'/ARG/g" -e 's/"[^"]*"/ARG/g'
}

is_commit() {
  printf '%s' "$1" | strip_quotes | grep -qE "$IS_COMMIT"
}

scan() {
  local found=""
  local files
  # `-z` обязателен: без него git цитирует пути с пробелами и не-ASCII, и
  # следующий `git diff -- "$f"` не находит такой файл. Гейт при этом молчит.
  files=$(git diff --cached --name-only -z 2>/dev/null | tr '\0' '\n') || return 0
  [ -z "$files" ] && return 0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    local pat="$PAT_ANY"
    if printf '%s' "$f" | grep -qE "$IS_CI"; then
      pat="$PAT_ANY|$PAT_CI"
    fi
    local hit
    # Заголовок `+++ b/<путь>` начинается с плюса и попадает в поиск наравне с
    # добавленными строками. Файл, названный `allow_failure: true.yaml`, из-за
    # этого блокировался при пустом содержимом.
    #
    # Склеиваем перенос строки: `run_tests || \` + `true` — то же подавление,
    # что и в одну строку, но однострочный поиск его не видит.
    hit=$(git diff --cached -U0 -- "$f" 2>/dev/null \
          | grep -E '^\+' \
          | grep -vE '^\+\+\+ ' \
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
  mkdir -p ci-scripts src .github/workflows "ci-scripts/with space"

  check() { # имя; ожидание пусто|непусто
    local got; got=$(scan)
    if [ "$2" = "пусто" ] && [ -n "$got" ]; then echo "ПРОВАЛ: $1 (получено: $got)"; fail=1; fi
    if [ "$2" = "непусто" ] && [ -z "$got" ]; then echo "ПРОВАЛ: $1"; fail=1; fi
  }
  yes_commit() { is_commit "$1" || { echo "ПРОВАЛ: не опознан коммит — $1"; fail=1; }; }
  no_commit()  { is_commit "$1" && { echo "ПРОВАЛ: принято за коммит — $1"; fail=1; }; }

  printf 'HIT=$(grep foo bar || true)\n' > src/normal.sh
  git add src/normal.sh
  check "'|| true' в обычном скрипте не должен ловиться" пусто
  git rm -q --cached src/normal.sh

  printf 'run_tests || true\n' > ci-scripts/check.sh
  git add ci-scripts/check.sh
  check "'|| true' в ci-scripts должен ловиться" непусто
  git rm -q --cached ci-scripts/check.sh

  { echo 'run_tests || \'; echo '  true'; } > ci-scripts/check.sh
  git add ci-scripts/check.sh
  check "'|| \\' с переносом строки должен ловиться" непусто
  git rm -q --cached ci-scripts/check.sh

  printf 'run_tests || true\n' > "ci-scripts/with space/check.sh"
  git add "ci-scripts/with space/check.sh"
  check "путь с пробелом должен ловиться" непусто
  git rm -q --cached "ci-scripts/with space/check.sh"

  printf 'ignoreFailures = true\n' > build.gradle.kts
  git add build.gradle.kts
  check "ignoreFailures должен ловиться в любом файле" непусто
  git rm -q --cached build.gradle.kts

  printf 'continue-on-error: true\n' > .github/workflows/ci.yml
  git add .github/workflows/ci.yml
  check "continue-on-error в GitHub Actions должен ловиться" непусто
  git rm -q --cached .github/workflows/ci.yml

  printf "sh 'make || true'\n" > Jenkinsfile
  git add Jenkinsfile
  check "'|| true' в Jenkinsfile должен ловиться" непусто
  git rm -q --cached Jenkinsfile

  printf 'hello\n' > 'ignoreFailures=true.txt'
  git add -- 'ignoreFailures=true.txt'
  check "имя файла не должно считаться подавлением" пусто
  git rm -q --cached -- 'ignoreFailures=true.txt'

  yes_commit 'git commit -m x'
  yes_commit 'cd foo && git commit'
  yes_commit 'git -c user.name=x commit -m y'
  yes_commit 'git -c user.name="Jane Doe" commit -m y'
  yes_commit 'git --no-pager commit -m y'
  yes_commit 'git --git-dir=/tmp/x commit -m y'
  no_commit  'git log --grep=commit'
  no_commit  'git diff --stat # what to commit'
  no_commit  'echo git commit'
  no_commit  'git restore --staged .'

  cd / && rm -rf "$t"
  [ "$fail" = 0 ] && echo "selftest ok" || exit 1
}

[ "${1:-}" = "--selftest" ] && { selftest; exit 0; }

# Хук висит на всех вызовах Bash, потому что матчер в settings.json умеет только имя
# инструмента. Отделяем коммит здесь: без этого блокируется любая команда, включая ту,
# которой изменение вынимают из индекса, и выхода из блокировки не остаётся.
PAYLOAD=$(timeout 2 cat 2>/dev/null || true)
is_commit "$PAYLOAD" || exit 0

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
