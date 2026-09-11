#!/bin/bash
# Мутационный гейт: доказать, что тесты ловят известную регрессию.
#
# Каждый файл *.patch из каталога мутаций применяется к рабочему дереву, тесты
# прогоняются, вердикт читается из JUnit XML. Мутант «убит», если хотя бы один
# тест упал; «выжил», если все зелёные. Файлы восстанавливаются всегда и
# сверяются по хэшу.
#
# Вердикт только по XML, не по коду возврата Gradle: с ignoreFailures = true
# Gradle возвращает 0 при упавших тестах, и гейт по коду возврата слеп. Старые
# XML удаляются перед каждым прогоном, иначе прошлый отчёт сойдёт за текущий.
#
# Использование:
#   mutation-gate.sh --mutations <каталог> [--gradle "<команда>"] [--project <корень>] [--results <подкаталог>]
#   mutation-gate.sh --selftest
#
# Переменные окружения с теми же именами: MG_GRADLE, MG_PROJECT, MG_RESULTS.
# По умолчанию: команда `./gradlew test`, корень `.`, XML ищутся в `*/build/test-results/*`.
#
# Коды выхода: 0 все мутанты убиты; 1 хотя бы один выжил; 2 инфраструктура
# (baseline красный, тесты не выполнялись, XML нет, патч не лёг, файл не
# восстановился). Молчаливого зелёного нет: ноль выполненных тестов это ошибка,
# а не успех, и тесты со skipped в счёт не идут.
set -u

GRADLE="${MG_GRADLE:-./gradlew test}"
PROJECT="${MG_PROJECT:-.}"
RESULTS="${MG_RESULTS:-build/test-results}"
MUTATIONS=""
LOG=/dev/null

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------- разбор JUnit XML ----------

xml_files() {
  find "$PROJECT" -type f -path "*/$RESULTS/*" -name '*.xml' 2>/dev/null | sort
}

clean_results() {
  find "$PROJECT" -type f -path "*/$RESULTS/*" -name '*.xml' -delete 2>/dev/null || true
}

# Одно число из открывающего тега по имени атрибута, 0 если атрибута нет.
attr() {
  local v
  v=$(printf '%s' "$1" | sed -n "s/.*[[:space:]]$2=\"\([0-9]*\)\".*/\1/p" | head -1)
  # Пустой поток sed не обрабатывает, поэтому подстановка нуля делается здесь,
  # а не через `sed 's/^$/0/'`: та на отсутствующем атрибуте молча даёт пустоту.
  printf '%s' "${v:-0}"
}

# Печатает «executed failures errors»: сумма по всем <testsuite> всех файлов.
# executed = tests - skipped: набор из одних пропущенных тестов ничего не проверил.
# Файл схлопывается в одну строку, поэтому тег с атрибутами на нескольких строках
# читается так же, как однострочный. Корневой <testsuites> не подходит под
# «<testsuite» плюс пробел и в сумму не попадает.
xml_totals() {
  local x=0 f=0 e=0 file tag
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    while IFS= read -r tag; do
      [ -z "$tag" ] && continue
      local n s
      n=$(attr "$tag" tests); s=$(attr "$tag" skipped)
      # skipped больше tests это битый отчёт; в минус не уходим, иначе
      # проверка «выполнено ноль» не сработает.
      [ "$s" -gt "$n" ] && s=$n
      x=$((x + n - s))
      f=$((f + $(attr "$tag" failures)))
      e=$((e + $(attr "$tag" errors)))
    done < <(tr '\n\r' '  ' < "$file" | grep -o '<testsuite[[:space:]][^>]*>')
  done < <(xml_files)
  printf '%s %s %s\n' "$x" "$f" "$e"
}

# Имена упавших тестов: classname.name, по одному в строке. Запись это всё от
# одного <testcase до следующего, поэтому многострочные теги не мешают.
# <system-out> и <system-err> вырезаются до поиска: слово <error> в выводе теста
# это не отказ теста.
xml_failed() {
  local file
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    tr '\n\r' '  ' < "$file" | awk '
      # Вывод тестов вырезается до разрезания на записи: строка «<testcase» в
      # логе теста иначе стала бы границей записи. Каждый блок отдельно, жадный
      # .* съел бы <failure/> между двумя блоками. Атрибуты у тега допускаются.
      function strip(body, op, cl,   s, rest) {
        while (match(body, op)) {
          s = RSTART; rest = substr(body, s)
          if (!match(rest, cl)) break
          body = substr(body, 1, s-1) substr(rest, RSTART+RLENGTH)
        }
        return body
      }
      {
        body = strip($0, "<system-out[^>]*>", "</system-out>")
        body = strip(body, "<system-err[^>]*>", "</system-err>")
        n = split(body, rec, /<testcase/)
        for (i = 2; i <= n; i++) {
          hdr = rec[i]; sub(/>.*/, "", hdr)
          if (hdr ~ /\/$/) continue                 # самозакрывающийся: упасть не мог
          cur = ""
          if (match(hdr, /classname="[^"]*"/)) cur = substr(hdr, RSTART+11, RLENGTH-12)
          if (match(hdr, /[[:space:]]name="[^"]*"/)) cur = cur "." substr(hdr, RSTART+7, RLENGTH-8)
          if (cur == "") cur = "(testcase без имени)"
          if (rec[i] ~ /<(failure|error)([[:space:]>]|\/>)/) print cur
        }
      }
    '
  done < <(xml_files) | sort -u
}

# ---------- прогон ----------

# Команда тестов задаётся пользователем и раскрывается eval, чтобы кавычки в
# `--tests 'a.B'` работали как в шелле. Это не граница доверия: кто задаёт
# MG_GRADLE, тот и так запускает команды на этой машине.
run_tests() {
  clean_results
  local rc=0
  (cd "$PROJECT" && eval "$GRADLE") >"$LOG" 2>&1 || rc=$?
  [ "$rc" != 0 ] && echo "  (команда тестов вернула $rc; вердикт по XML)" >&2
  xml_totals
}

# core.quotePath=false: иначе не-ASCII путь приходит в кавычках с восьмеричными
# кодами, и такой файл «не существует» для бэкапа и хэша.
files_of_patch() {
  git -C "$PROJECT" -c core.quotePath=false apply --numstat "$1" 2>/dev/null | awk -F'\t' '{print $3}'
}

hash_files() {
  local f
  for f in "$@"; do
    if [ -f "$PROJECT/$f" ]; then sha256sum "$PROJECT/$f" | cut -d' ' -f1; else echo absent; fi
  done
}

BACKUP=""
CUR_FILES=()
restore_current() {
  [ -z "$BACKUP" ] && return 0
  local f
  for f in "${CUR_FILES[@]}"; do
    if [ -f "$BACKUP/$f" ]; then
      mkdir -p "$(dirname "$PROJECT/$f")"
      cp "$BACKUP/$f" "$PROJECT/$f"
    else
      # Бэкапа нет, значит до патча файла не было: патч его создал, убираем.
      rm -f "$PROJECT/$f"
    fi
  done
}
trap 'restore_current' EXIT

gate() {
  [ -d "$MUTATIONS" ] || { echo "нет каталога мутаций: $MUTATIONS" >&2; exit 2; }
  git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "не git-репозиторий: $PROJECT (нужен для git apply)" >&2; exit 2; }
  local patches=()
  mapfile -t patches < <(find "$MUTATIONS" -maxdepth 1 -name '*.patch' | sort)
  [ "${#patches[@]}" = 0 ] && { echo "в $MUTATIONS нет *.patch" >&2; exit 2; }

  LOG=$(mktemp) || exit 2
  BACKUP=$(mktemp -d) || exit 2

  echo "baseline: $GRADLE"
  local x f e
  read -r x f e <<<"$(run_tests)"
  if [ "$x" = 0 ]; then
    echo "baseline: ни один тест не выполнен (tests минус skipped = 0) или XML нет. Проверь --gradle и --results. Лог: $LOG" >&2
    exit 2
  fi
  if [ $((f + e)) != 0 ]; then
    echo "baseline красный: failures=$f errors=$e из $x. Мутации на красном baseline ничего не доказывают." >&2
    xml_failed | sed 's/^/  /' >&2
    exit 2
  fi
  echo "baseline: $x тестов выполнено, зелёный"

  local killed=0 survived=0 errors=0 p name report=""
  for p in "${patches[@]}"; do
    name=$(basename "$p" .patch)
    mapfile -t CUR_FILES < <(files_of_patch "$p")
    if [ "${#CUR_FILES[@]}" = 0 ]; then
      report+="$name	ERROR	патч не разобран (git apply --numstat пуст)"$'\n'; errors=$((errors+1)); continue
    fi
    local before after fl failed
    before=$(hash_files "${CUR_FILES[@]}")
    for fl in "${CUR_FILES[@]}"; do
      mkdir -p "$BACKUP/$(dirname "$fl")"; [ -f "$PROJECT/$fl" ] && cp "$PROJECT/$fl" "$BACKUP/$fl"
    done
    if ! git -C "$PROJECT" apply --check "$p" 2>/dev/null; then
      report+="$name	ERROR	патч не ложится на текущее дерево"$'\n'; errors=$((errors+1)); CUR_FILES=(); continue
    fi
    git -C "$PROJECT" apply "$p"
    read -r x f e <<<"$(run_tests)"
    failed=$(xml_failed | tr '\n' ' ')
    git -C "$PROJECT" apply -R "$p" 2>/dev/null || true
    restore_current
    after=$(hash_files "${CUR_FILES[@]}")
    CUR_FILES=()
    if [ "$before" != "$after" ]; then
      echo "$name: файлы не восстановились после мутации, дерево в неизвестном состоянии" >&2
      exit 2
    fi
    if [ "$x" = 0 ]; then
      report+="$name	ERROR	ни один тест не выполнен после мутации (сборка не прошла?), лог: $LOG"$'\n'; errors=$((errors+1))
    elif [ $((f + e)) != 0 ]; then
      report+="$name	KILLED	$failed"$'\n'; killed=$((killed+1))
    else
      report+="$name	SURVIVED	$x тестов зелёные, регрессию никто не поймал"$'\n'; survived=$((survived+1))
    fi
  done

  echo
  printf '%s' "$report" | column -t -s $'\t' 2>/dev/null || printf '%s' "$report"
  echo
  echo "убито $killed, выжило $survived, ошибок $errors"
  [ "$errors" != 0 ] && exit 2
  [ "$survived" != 0 ] && exit 1
  exit 0
}

# ---------- селф-тест ----------

selftest() {
  local fail=0 t root
  t=$(mktemp -d) || exit 1
  root="$t/proj"
  mkdir -p "$root/src/main" "$t/m-killed" "$t/m-both" "$t/m-bad" "$t/m cyr space"
  cd "$root" || exit 1
  git init -q . && git config user.email t@t && git config user.name t && git config core.autocrlf false
  printf 'A=1\nB=2\n' > src/main/App.txt
  printf 'C=3\n' > 'src/main/Файл.txt'
  printf 'build/\n' > .gitignore

  # Поддельный gradlew: пишет JUnit XML по содержимому файлов и ВСЕГДА выходит с 0,
  # как настоящий Gradle при ignoreFailures = true. Тест b падает, если A изменили,
  # тест c падает, если изменили кириллический файл. FAKE_XML_SRC подменяет отчёт
  # готовым файлом, чтобы гонять разбор XML на чужих форматах.
  cat > gradlew <<'FAKE'
#!/bin/bash
mkdir -p build/test-results/test
[ -n "${FAKE_NO_XML:-}" ] && exit 0
if [ -n "${FAKE_XML_SRC:-}" ]; then cp "$FAKE_XML_SRC" build/test-results/test/TEST-X.xml; exit 0; fi
b=0; grep -q 'A=9' src/main/App.txt && b=1
c=0; grep -q 'C=9' 'src/main/Файл.txt' && c=1
[ -n "${FAKE_RED:-}" ] && b=1
f=$((b + c))
bb=''; [ "$b" = 1 ] && bb='<failure message="x">boom</failure>'
cb=''; [ "$c" = 1 ] && cb='<failure message="y">bang</failure>'
cat > build/test-results/test/TEST-AppTest.xml <<X
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="AppTest" tests="3" skipped="0" failures="$f" errors="0" timestamp="2026-01-01T00:00:00" time="0.1">
  <testcase name="a" classname="AppTest" time="0.01"/>
  <testcase name="b" classname="AppTest" time="0.01">$bb</testcase>
  <testcase name="c" classname="AppTest" time="0.01">$cb</testcase>
</testsuite>
X
exit 0
FAKE
  chmod +x gradlew
  git add -A && git commit -qm init

  sed -i 's/A=1/A=9/' src/main/App.txt && git diff > "$t/m-killed/01-a.patch" && git checkout -q -- .
  cp "$t/m-killed/01-a.patch" "$t/m-both/01-a.patch"
  sed -i 's/B=2/B=9/' src/main/App.txt && git diff > "$t/m-both/02-b.patch" && git checkout -q -- .
  sed 's/A=1/A=7/' "$t/m-killed/01-a.patch" > "$t/m-bad/01-bad.patch"
  sed -i 's/C=3/C=9/' 'src/main/Файл.txt' && git -c core.quotePath=false diff > "$t/m cyr space/01 c.patch" && git checkout -q -- .
  local orig
  orig=$(sha256sum src/main/App.txt 'src/main/Файл.txt')

  check() { # ожидание, факт, описание, вывод
    if [ "$1" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (ожидал $1, получил $2)"; echo "$4" | sed 's/^/     /'; fail=1; fi
  }
  local out rc

  out=$("$SELF" --mutations "$t/m-killed" --project "$root" 2>&1); rc=$?
  check 0 "$rc" "мутант убит: код 0" "$out"
  printf '%s' "$out" | grep -q 'KILLED.*AppTest.b' ; check 0 $? "убитый мутант назван вместе с упавшим тестом" "$out"

  out=$("$SELF" --mutations "$t/m-both" --project "$root" 2>&1); rc=$?
  check 1 "$rc" "выживший мутант: код 1" "$out"
  printf '%s' "$out" | grep -q '02-b.*SURVIVED' ; check 0 $? "выживший назван" "$out"
  [ "$(sha256sum src/main/App.txt 'src/main/Файл.txt')" = "$orig" ]; check 0 $? "файлы восстановлены по хэшу" "$out"
  [ -z "$(git status --porcelain)" ]; check 0 $? "дерево чистое после прогона" "$(git status --short)"

  out=$("$SELF" --mutations "$t/m cyr space" --project "$root" 2>&1); rc=$?
  check 0 "$rc" "кириллический файл и пробелы в пути патча: код 0" "$out"
  printf '%s' "$out" | grep -q '01 c.*KILLED.*AppTest.c' ; check 0 $? "кириллический мутант назван" "$out"
  [ "$(sha256sum src/main/App.txt 'src/main/Файл.txt')" = "$orig" ]; check 0 $? "кириллический файл восстановлен по хэшу" "$out"

  out=$(FAKE_RED=1 "$SELF" --mutations "$t/m-killed" --project "$root" 2>&1); rc=$?
  check 2 "$rc" "красный baseline: код 2, мутации не гоняются" "$out"

  out=$(FAKE_NO_XML=1 "$SELF" --mutations "$t/m-killed" --project "$root" 2>&1); rc=$?
  check 2 "$rc" "нет XML: код 2, а не тихий успех" "$out"

  # Старый красный отчёт лежит с прошлого прогона: гейт обязан его удалить,
  # иначе baseline покажется красным без причины.
  mkdir -p build/test-results/test
  printf '<testsuite name="Old" tests="1" failures="1" errors="0"><testcase name="z" classname="Old"><failure/></testcase></testsuite>' > build/test-results/test/TEST-Old.xml
  out=$("$SELF" --mutations "$t/m-killed" --project "$root" 2>&1); rc=$?
  check 0 "$rc" "старый XML удалён перед прогоном" "$out"

  out=$("$SELF" --mutations "$t/m-bad" --project "$root" 2>&1); rc=$?
  check 2 "$rc" "патч не ложится: код 2" "$out"
  [ -z "$(git status --porcelain)" ]; check 0 $? "дерево чистое после неудачного патча" "$(git status --short)"

  out=$("$SELF" --mutations "$t/empty-dir-none" --project "$root" 2>&1); rc=$?
  check 2 "$rc" "нет каталога мутаций: код 2" "$out"

  # Разбор XML на чужих форматах: функции вызываются напрямую на подложенном файле.
  xml_case() { # описание, ожидаемые totals, ожидаемые failed, содержимое
    local d="$t/xml"; rm -rf "$d"; mkdir -p "$d/build/test-results/test"
    printf '%s' "$4" > "$d/build/test-results/test/TEST-X.xml"
    local tot fl
    tot=$(PROJECT="$d" xml_totals); fl=$(PROJECT="$d" xml_failed | tr '\n' ' ' | sed 's/ $//')
    check "$2" "$tot" "$1: totals" "$tot"
    check "$3" "$fl" "$1: упавшие" "$fl"
  }
  xml_case "все тесты skipped считаются невыполненными" "0 0 0" "" \
    '<testsuite name="S" tests="2" skipped="2" failures="0" errors="0"><testcase name="a" classname="S"><skipped/></testcase><testcase name="b" classname="S"><skipped/></testcase></testsuite>'
  xml_case "два testsuite в одном файле суммируются" "3 1 0" "T.q" \
    '<testsuites><testsuite name="S" tests="1" failures="0" errors="0"><testcase name="p" classname="S"/></testsuite><testsuite name="T" tests="2" failures="1" errors="0"><testcase name="q" classname="T"><failure message="m">x</failure></testcase><testcase name="r" classname="T"/></testsuite></testsuites>'
  xml_case "тег на нескольких строках и failure без пробела" "1 1 0" "M.n" \
    $'<testsuites>\n<testsuite\n  name="M"\n  tests="1"\n  failures="1"\n  errors="0">\n  <testcase\n    name="n"\n    classname="M">\n    <failure/>\n  </testcase>\n</testsuite>\n</testsuites>'
  xml_case "error внутри system-out не считается падением" "2 0 0" "" \
    '<testsuite name="L" tests="2" failures="0" errors="0"><testcase name="log" classname="L"><system-out><error message="not a failure"/></system-out></testcase><testcase name="ok" classname="L"/></testsuite>'
  xml_case "error как отказ теста считается" "1 0 1" "E.e" \
    '<testsuite name="E" tests="1" failures="0" errors="1"><testcase name="e" classname="E"><error type="x">boom</error></testcase></testsuite>'
  xml_case "failure между двумя system-out не теряется" "1 1 0" "G.g" \
    '<testsuite name="G" tests="1" failures="1" errors="0"><testcase name="g" classname="G"><system-out>a</system-out><failure/><system-out>b</system-out></testcase></testsuite>'
  xml_case "skipped больше tests не уходит в минус" "0 0 0" "" \
    '<testsuite name="Z" tests="0" skipped="2" failures="0" errors="0"></testsuite>'
  xml_case "system-out с атрибутами тоже вырезается" "2 1 0" "H.bad" \
    '<testsuite name="H" tests="2" failures="1" errors="0"><testcase name="green" classname="H"><system-out attr="1"><error/></system-out></testcase><testcase name="bad" classname="H"><failure/></testcase></testsuite>'
  xml_case "литеральный testcase в выводе теста не режет запись" "1 1 0" "I.x" \
    '<testsuite name="I" tests="1" failures="1" errors="0"><testcase name="x" classname="I"><system-out>log <testcase foo="bar"/> here</system-out><failure/></testcase></testsuite>'
  xml_case "testcase без имени всё равно попадает в список" "1 1 0" "(testcase без имени)" \
    '<testsuite name="J" tests="1" failures="1" errors="0"><testcase time="0.01"><failure/></testcase></testsuite>'

  # Прерывание между apply и apply -R: файл, созданный патчем, обязан исчезнуть.
  printf 'new\n' > src/main/New.txt && git add src/main/New.txt && git diff --cached > "$t/new.patch" && git reset -q && rm src/main/New.txt
  ( PROJECT="$root"; BACKUP=$(mktemp -d); mapfile -t CUR_FILES < <(files_of_patch "$t/new.patch")
    git -C "$root" apply "$t/new.patch"; restore_current; [ ! -e "$root/src/main/New.txt" ] )
  check 0 $? "файл, созданный патчем, удалён при восстановлении" "$(git status --short)"

  cd / && rm -rf "$t"
  [ "$fail" = 0 ] && echo "selftest ok" || exit 1
}

# ---------- аргументы ----------

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  while [ $# -gt 0 ]; do
    case "$1" in
      --mutations) MUTATIONS="$2"; shift 2 ;;
      --gradle)    GRADLE="$2"; shift 2 ;;
      --project)   PROJECT="$2"; shift 2 ;;
      --results)   RESULTS="$2"; shift 2 ;;
      --selftest)  selftest; exit 0 ;;
      -h|--help)   usage; exit 0 ;;
      *) echo "неизвестный аргумент: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
  [ -z "$MUTATIONS" ] && { usage >&2; exit 2; }
  gate
fi
