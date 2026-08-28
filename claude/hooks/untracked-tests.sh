#!/bin/bash
# Неотслеживаемые файлы в тестовом дереве — работа, которой нет ни в одной ветке.
# Один git clean, и её нет нигде. Один раз так уже висел guard-тест на 299 строк.
#
# Гейт на завершение хода: в сомнении пропускать, не блокировать.
set -u

# Тестовые корни разных экосистем. Каталог, а не имя файла: имена расходятся
# сильнее, чем размещение, и ложное срабатывание по имени дороже пропуска.
#
# Голый `test/` намеренно НЕ включён: так называют и каталоги с данными
# (`test/artifacts/`), и блокировать их значит нарушить собственное правило
# «в сомнении пропускать».
TEST_DIRS='(^|/)(src/test|src/it|tests|spec|__tests__)/'

scan() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  # `ls-files --others` отдаёт пути как есть и по одному на запись, разделяя NUL.
  # `status --porcelain` здесь не годится: он цитирует пути с пробелами и
  # эскейпит не-ASCII восьмеричными кодами, а разбор такой строки полем awk
  # молча терял ровно те файлы, ради которых хук написан.
  git ls-files --others --exclude-standard -z 2>/dev/null \
    | tr '\0' '\n' \
    | grep -E "$TEST_DIRS" || true
}

selftest() {
  local t fail=0
  t=$(mktemp -d) || exit 1
  cd "$t" || exit 1
  git init -q . && git config user.email t@t && git config user.name t
  mkdir -p src/test/kotlin tests docs test-utils test/artifacts "src/test/cats with space" "tests/каталог"

  check() { # имя; ожидание пусто|непусто; [ожидаемая подстрока в выводе]
    local got; got=$(scan)
    if [ "$2" = "пусто" ] && [ -n "$got" ]; then echo "ПРОВАЛ: $1 (получено: $got)"; fail=1; fi
    if [ "$2" = "непусто" ] && [ -z "$got" ]; then echo "ПРОВАЛ: $1"; fail=1; fi
    if [ -n "${3:-}" ] && [ "${got#*$3}" = "$got" ]; then
      echo "ПРОВАЛ: $1 — в выводе нет '$3', получено: $got"; fail=1
    fi
  }

  check "чистый репозиторий" пусто

  echo x > docs/note.md
  check "неотслеживаемый файл вне тестов не ловится" пусто

  echo x > src/test/kotlin/FooTest.kt
  check "src/test ловится" непусто "src/test/kotlin/FooTest.kt"
  rm src/test/kotlin/FooTest.kt

  echo x > tests/test_foo.py
  check "tests/ ловится" непусто "tests/test_foo.py"
  rm tests/test_foo.py

  echo x > "src/test/cats with space/a.txt"
  check "путь с пробелом ловится и печатается целиком" непусто "src/test/cats with space/a.txt"
  rm "src/test/cats with space/a.txt"

  echo x > "tests/каталог/test.py"
  check "не-ASCII путь ловится и печатается целиком" непусто "tests/каталог/test.py"
  rm "tests/каталог/test.py"

  echo x > test/artifacts/data.txt
  check "каталог test/ с данными не блокируется" пусто
  rm test/artifacts/data.txt

  echo x > test-utils/helper.kt
  check "test-utils не тестовый каталог, не ловится" пусто

  echo "node_modules/" > .gitignore
  mkdir -p tests/node_modules && echo x > tests/node_modules/junk.js
  check "игнорируемое git не ловится" пусто

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
