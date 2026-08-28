#!/bin/bash
# Неотслеживаемые файлы в тестовом дереве — работа, которой нет ни в одной ветке.
# Один git clean, и её нет нигде. Один раз так уже висел guard-тест на 299 строк.
#
# Гейт на завершение хода: в сомнении пропускать, не блокировать.
set -u

# Тестовые корни разных экосистем. Каталог, а не имя файла: имена расходятся
# сильнее, чем размещение, и ложное срабатывание по имени дороже пропуска.
TEST_DIRS='(^|/)(src/test|src/it|tests|test|spec|__tests__)/'

scan() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git status --porcelain -uall 2>/dev/null \
    | awk -v re="$TEST_DIRS" '$1=="??" && $2 ~ re {print $2}'
}

selftest() {
  local t fail=0
  t=$(mktemp -d) || exit 1
  cd "$t" || exit 1
  git init -q . && git config user.email t@t && git config user.name t
  mkdir -p src/test/kotlin tests docs test-utils

  check() { # имя; ожидание пусто|непусто
    local got; got=$(scan)
    if [ "$2" = "пусто" ] && [ -n "$got" ]; then echo "ПРОВАЛ: $1"; fail=1; fi
    if [ "$2" = "непусто" ] && [ -z "$got" ]; then echo "ПРОВАЛ: $1"; fail=1; fi
  }

  check "чистый репозиторий" пусто

  echo x > docs/note.md
  check "неотслеживаемый файл вне тестов не ловится" пусто

  echo x > src/test/kotlin/FooTest.kt
  check "src/test ловится" непусто
  rm src/test/kotlin/FooTest.kt

  echo x > tests/test_foo.py
  check "tests/ ловится" непусто
  rm tests/test_foo.py

  echo x > test-utils/helper.kt
  check "test-utils не тестовый каталог, не ловится" пусто

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
