#!/bin/bash
# Неотслеживаемые файлы в тестовом дереве — работа, которой нет ни в одной ветке.
# Один git clean, и её нет нигде. Один раз так уже висел guard-тест на 299 строк.
#
# Гейт на завершение хода: в сомнении пропускать, не блокировать.
set -u

# Тестовые корни разных экосистем. Каталог, а не имя файла: имена расходятся
# сильнее, чем размещение, и ложное срабатывание по имени дороже пропуска.
#
# НЕ включены намеренно, оба по одной причине — так называют не только тесты:
#   test/  — каталоги с данными (test/artifacts/);
#   spec/  — спецификации API (spec/openapi.yaml), а не только RSpec.
# Блокировать их значит нарушить собственное правило «в сомнении пропускать».
TEST_DIRS='(^|/)(src/test|src/it|tests|__tests__)/'

scan() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  # `ls-files --others` отдаёт пути как есть и по одному на запись, разделяя NUL.
  # `status --porcelain` здесь не годится: он цитирует пути с пробелами и
  # эскейпит не-ASCII восьмеричными кодами, а разбор такой строки полем awk
  # молча терял ровно те файлы, ради которых хук написан.
  #
  # Запись, кончающаяся на `/`, — это вложенный репозиторий, схлопнутый в одну
  # строку. `git clean -fd` внутрь него не заходит, терять там нечего.
  git ls-files --others --exclude-standard -z 2>/dev/null \
    | tr '\0' '\n' \
    | grep -v '/$' \
    | grep -E "$TEST_DIRS" || true
}

selftest() {
  local t fail=0
  t=$(mktemp -d) || exit 1
  cd "$t" || exit 1
  git init -q . && git config user.email t@t && git config user.name t
  mkdir -p src/test/kotlin src/it tests __tests__ spec docs test-utils test/artifacts \
           "src/test/cats with space" "tests/каталог"

  check() { # имя; ожидание пусто|непусто; [обязательная подстрока вывода]
    local got; got=$(scan)
    if [ "$2" = "пусто" ] && [ -n "$got" ]; then echo "ПРОВАЛ: $1 (получено: $got)"; fail=1; fi
    if [ "$2" = "непусто" ] && [ -z "$got" ]; then echo "ПРОВАЛ: $1"; fail=1; fi
    if [ -n "${3:-}" ] && [ "${got#*$3}" = "$got" ]; then
      echo "ПРОВАЛ: $1 — в выводе нет '$3', получено: $got"; fail=1
    fi
  }
  one() { # каталог; ожидание; имя случая
    echo x > "$1/probe.txt"
    check "$3" "$2" $([ "$2" = непусто ] && echo "$1/probe.txt")
    rm "$1/probe.txt"
  }

  check "чистый репозиторий" пусто

  # По одному случаю на каждую альтернативу шаблона: иначе урезание TEST_DIRS
  # проходит мимо селф-теста, и он остаётся зелёным при сломанном хуке.
  one src/test/kotlin непусто "src/test ловится"
  one src/it         непусто "src/it ловится"
  one tests          непусто "tests ловится"
  one __tests__      непусто "__tests__ ловится"

  one docs       пусто "файл вне тестов не ловится"
  one spec       пусто "spec — это ещё и спецификации API, не ловится"
  one test/artifacts пусто "каталог test/ с данными не ловится"
  one test-utils пусто "test-utils не тестовый каталог"

  echo x > "src/test/cats with space/a.txt"
  check "путь с пробелом ловится целиком" непусто "src/test/cats with space/a.txt"
  rm "src/test/cats with space/a.txt"

  echo x > "tests/каталог/test.py"
  check "не-ASCII путь ловится целиком" непусто "tests/каталог/test.py"
  rm "tests/каталог/test.py"

  echo "node_modules/" > .gitignore
  mkdir -p tests/node_modules && echo x > tests/node_modules/junk.js
  check "игнорируемое git не ловится" пусто
  rm -rf tests/node_modules .gitignore

  # Вложенный репозиторий: git clean -fd его пропускает, терять нечего.
  mkdir -p tests/nested && (cd tests/nested && git init -q . && git config user.email t@t && git config user.name t)
  echo x > tests/nested/test_foo.py
  check "вложенный репозиторий не блокирует" пусто
  rm -rf tests/nested

  # Вне git-репозитория хук обязан молчать.
  local outside; outside=$(mktemp -d)
  mkdir -p "$outside/tests" && echo x > "$outside/tests/test_foo.py"
  ( cd "$outside" && [ -n "$(scan)" ] ) && { echo "ПРОВАЛ: вне git-репозитория должен молчать"; fail=1; }
  rm -rf "$outside"

  cd / && rm -rf "$t"
  [ "$fail" = 0 ] && echo "selftest ok" || exit 1
}

[ "${1:-}" = "--selftest" ] && { selftest; exit 0; }

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
FILES=$(scan)
[ -z "$FILES" ] && exit 0
echo "Неотслеживаемые файлы в тестовом дереве — вне git, потеряются от одного git clean:" >&2
echo "$FILES" >&2
exit 2
