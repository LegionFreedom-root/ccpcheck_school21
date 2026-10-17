#!/usr/bin/env bash
# ccheck.sh — проверка C-проекта по требованиям Школы 21.
#
# Запуск:
#   ./ccheck.sh              — интерактивное меню
#   ./ccheck.sh 1            — полная проверка (формат + cppcheck + сборка + запуск + память)
#   ./ccheck.sh 2            — проверки без компиляции
#   ./ccheck.sh 1 src/main.c — проверить конкретный файл или каталог
#
# Переменные окружения:
#   CCHECK_SOURCE        — файл или каталог с исходниками (по умолчанию '.')
#   CCHECK_BINARY        — имя бинарника (по умолчанию ./main.out)
#   CCHECK_BUILD_CMD     — своя команда сборки (например 'make all')
#   CCHECK_CFLAGS        — доп. флаги компиляции
#   CCHECK_RUN_ARGS      — аргументы запуска программы
#   CCHECK_TIMEOUT       — лимит времени на запуск, сек (по умолчанию 60)
#   CCHECK_STYLE         — google (по умолчанию, как в Школе 21) | custom
#   CCHECK_CPPCHECK_STRICT=1 — чистый --enable=all без подавления шума
#   CCHECK_LEAKS_MODE    — atexit (по умолчанию) | dylib

set -uo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly LEAKS_DYLIB='/usr/local/lib/libLeaksAtExit.dylib'
readonly XCODE_DYLIB='/Applications/Xcode.app/Contents/Developer/usr/lib/libLeaksAtExit.dylib'

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
SOURCES=()
BUILT_BINARY=''
CLANG_FORMAT=''
GENERATED_CONFIG=''
OS_NAME="$(uname -s 2>/dev/null || echo unknown)"

info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; ((PASS_COUNT+=1)); }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; ((WARN_COUNT+=1)); }
fail() { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*" >&2; ((FAIL_COUNT+=1)); }
head1(){ printf '\n%s===== %s =====%s\n' "$BOLD" "$*" "$NC"; }

need_tool() {
    command -v "$1" >/dev/null 2>&1 && return 0
    fail "Не найдена утилита '$1'."
    return 1
}

summary() {
    printf '\n========== РЕЗУЛЬТАТ ==========\n'
    printf 'Успешно: %d | Ошибок: %d | Предупреждений: %d\n' \
        "$PASS_COUNT" "$FAIL_COUNT" "$WARN_COUNT"
    (( FAIL_COUNT == 0 ))
}

# ---------------------------------------------------------------- clang-format

# В Школе 21 clang-format может быть не в PATH: он лежит внутри Xcode
# или ставится через brew. Поэтому перебираем все типичные расположения.
find_clang_format() {
    [[ -n "$CLANG_FORMAT" ]] && return 0
    local candidate
    local -a candidates=(
        clang-format
        clang-format-18 clang-format-17 clang-format-16
        clang-format-15 clang-format-14 clang-format-13 clang-format-12
        /opt/homebrew/bin/clang-format
        /opt/homebrew/opt/llvm/bin/clang-format
        /opt/homebrew/opt/clang-format/bin/clang-format
        /usr/local/bin/clang-format
        /usr/local/opt/llvm/bin/clang-format
        /usr/local/opt/clang-format/bin/clang-format
        /Applications/Xcode.app/Contents/Developer/usr/bin/clang-format
        /Library/Developer/CommandLineTools/usr/bin/clang-format
    )
    for candidate in "${candidates[@]}"; do
        if command -v "$candidate" >/dev/null 2>&1; then
            CLANG_FORMAT="$candidate"
            info "clang-format: $(command -v "$candidate") ($("$candidate" --version 2>/dev/null | head -n1))"
            return 0
        fi
    done
    fail 'clang-format не найден ни в PATH, ни в Xcode/Homebrew.'
    say_install_hint
    return 1
}

say_install_hint() {
    if [[ "$OS_NAME" == Darwin ]]; then
        printf '  Установка: %sbrew install clang-format%s\n' "$BOLD" "$NC"
        printf '  Либо:      export PATH="/Applications/Xcode.app/Contents/Developer/usr/bin:$PATH"\n'
    else
        printf '  Установка: %ssudo apt install clang-format%s\n' "$BOLD" "$NC"
    fi
}

# Как и в ранней версии — конфиг генерируется в корне проекта.
# Существующий .clang-format не перезаписывается.
ensure_format_config() {
    local dir='.'
    [[ -n "${CCHECK_SOURCE:-}" && -d "${CCHECK_SOURCE:-}" ]] && dir="$CCHECK_SOURCE"
    local config="$dir/.clang-format"

    if [[ -f "$config" ]]; then
        info "Используется существующий $config"
        FORMAT_CONFIG_DIR="$dir"
        return 0
    fi

    if [[ "${CCHECK_STYLE:-google}" == custom ]]; then
        cat > "$config" <<'EOF'
---
Language: Cpp
BasedOnStyle: Google
IndentWidth: 4
ContinuationIndentWidth: 4
ColumnLimit: 110
UseTab: Never
EOF
    else
        # Стандарт Школы 21: чистый Google style.
        cat > "$config" <<'EOF'
---
Language: Cpp
BasedOnStyle: Google
EOF
    fi || { fail "Не удалось создать $config"; return 1; }

    GENERATED_CONFIG="$config"
    FORMAT_CONFIG_DIR="$dir"
    ok "Создан $config (стиль: ${CCHECK_STYLE:-google})"
}

run_format_check() {
    head1 'clang-format'
    find_clang_format || return 1
    ensure_format_config || return 1

    local file failed=0
    for file in "${SOURCES[@]}"; do
        local diff_out
        diff_out="$("$CLANG_FORMAT" --style=file --assume-filename="$file" "$file" 2>/dev/null \
            | diff -u --label "$file" --label "$file (clang-format)" -- "$file" - )"
        if [[ -z "$diff_out" ]]; then
            ok "формат: $file"
        else
            fail "Нарушение форматирования: $file"
            printf '%s\n' "$diff_out"
            failed=1
        fi
    done
    (( failed == 0 ))
}

run_format_fix() {
    head1 'clang-format -i'
    find_clang_format || return 1
    ensure_format_config || return 1

    local file failed=0
    for file in "${SOURCES[@]}"; do
        if "$CLANG_FORMAT" --style=file -i "$file"; then
            info "отформатирован: $file"
        else
            fail "не удалось отформатировать: $file"; failed=1
        fi
    done
    (( failed == 0 )) && ok "Форматирование применено к ${#SOURCES[@]} файлам"
    (( failed == 0 ))
}

# ------------------------------------------------------------------- cppcheck

run_cppcheck() {
    head1 'cppcheck'
    need_tool cppcheck || return 1

    local -a args=(--enable=all --suppress=missingIncludeSystem --error-exitcode=1 --inline-suppr)
    if [[ "${CCHECK_CPPCHECK_STRICT:-0}" != 1 ]]; then
        # Пофайловый анализ учебного проекта стабильно шумит этими проверками.
        args+=(--suppress=unusedFunction --suppress=checkersReport)
    # Если strict-режим ВЫКЛЮЧЕН (unusedFunction подавлен), мы можем безопасно использовать многопоточность
        command -v nproc >/dev/null 2>&1 && args+=(-j "$(nproc)")
    else
        # Если мы в STRICT режиме, unusedFunction ДОЛЖЕН работать.
        # Поэтому мы НЕ добавляем флаг -j, чтобы cppcheck работал в один поток и смог проверить функции.
        info "cppcheck: Strict-режим. Анализ выполняется в один поток для проверки unusedFunction."
    fi
    info "cppcheck: файлов ${#SOURCES[@]}"
    if cppcheck "${args[@]}" "${SOURCES[@]}"; then
        ok 'cppcheck: проблем не найдено'
        return 0
    fi
    fail 'cppcheck нашёл ошибки.'
    return 1
}

# ----------------------------------------------------------------- компиляция

compile_project() {
    head1 "Компиляция (${1:-normal})"
    local mode="${1:-normal}"
    local base="${CCHECK_BINARY:-./main.out}"
    local output="$base"
    local -a src=() flags=() extra=()
    local compiler file has_cxx=0

    [[ "$mode" == asan ]] && output="${base%.out}.asan.out"

    if [[ -n "${CCHECK_BUILD_CMD:-}" ]]; then
        [[ "$mode" == asan ]] && warn 'CCHECK_BUILD_CMD задан: флаг -fsanitize=address не добавляется автоматически.'
        info "Сборка: $CCHECK_BUILD_CMD"
        if bash -o pipefail -c "$CCHECK_BUILD_CMD"; then
            ok 'Сборка успешна'; BUILT_BINARY="$base"; return 0
        fi
        fail 'Сборка завершилась с ошибкой.'; return 1
    fi

    for file in "${SOURCES[@]}"; do
        case "$file" in
            *.c) src+=("$file") ;;
            *.cc|*.cpp|*.cxx) src+=("$file"); has_cxx=1 ;;
        esac
    done
    if (( ${#src[@]} == 0 )); then
        fail 'Нет файлов реализации для компиляции (найдены только заголовки).'
        return 1
    fi

    if (( has_cxx )); then
        compiler="${CXX:-g++}"; flags=(-Wall -Werror -Wextra -g)
    else
        compiler="${CC:-gcc}"; flags=(-Wall -Werror -Wextra -std=c11 -g)
    fi
    need_tool "$compiler" || return 1

    if [[ -n "${CCHECK_CFLAGS:-}" ]]; then
        read -r -a extra <<< "$CCHECK_CFLAGS"
        flags+=("${extra[@]}")
    fi
    [[ "$mode" == asan ]] && flags+=(-fsanitize=address -fno-omit-frame-pointer)

    info "$compiler ${flags[*]} ${src[*]} -o $output"
    if "$compiler" "${flags[@]}" "${src[@]}" -o "$output"; then
        ok "Скомпилировано: $output"; BUILT_BINARY="$output"; return 0
    fi
    fail 'Ошибка компиляции.'
    return 1
}

resolve_binary() {
    printf '%s' "${1:-${BUILT_BINARY:-${CCHECK_BINARY:-./main.out}}}"
}

run_program() {
    head1 'Запуск программы'
    local binary; binary="$(resolve_binary "${1:-}")"
    local -a run_args=() launcher=()
    local status=0

    [[ -x "$binary" ]] || { fail "Нет исполняемого файла '$binary'."; return 1; }
    [[ -n "${CCHECK_RUN_ARGS:-}" ]] && read -r -a run_args <<< "$CCHECK_RUN_ARGS"
    command -v timeout >/dev/null 2>&1 && launcher=(timeout "${CCHECK_TIMEOUT:-60}")

    info "Запуск: $binary ${run_args[*]-}"
    "${launcher[@]+"${launcher[@]}"}" "$binary" ${run_args[@]+"${run_args[@]}"} </dev/null || status=$?

    case "$status" in
        0)   ok 'Программа завершилась с кодом 0'; return 0 ;;
        124) fail "Превышен лимит времени ${CCHECK_TIMEOUT:-60} с." ;;
        *)   fail "Программа завершилась с кодом $status." ;;
    esac
    return 1
}

# --------------------------------------------------------------------- память

# macOS: leaks. Требует симлинк libLeaksAtExit.dylib для режима dylib.
check_leaks_setup() {
    [[ -e "$LEAKS_DYLIB" ]] && return 0
    warn "Нет $LEAKS_DYLIB"
    printf '  Создай симлинк:\n'
    printf '    %scd /usr/local/lib && ln -s %s%s\n' "$BOLD" "$XCODE_DYLIB" "$NC"
    return 1
}

run_leaks() {
    head1 'leaks (macOS)'
    need_tool leaks || return 1
    local binary; binary="$(resolve_binary "${1:-}")"
    local -a run_args=()
    local status=0

    [[ -x "$binary" ]] || { fail "Нет исполняемого файла '$binary'. Сначала собери программу."; return 1; }
    [[ "$binary" == *asan* ]] && warn 'Бинарник собран с ASan — leaks с ним конфликтует.'
    [[ -n "${CCHECK_RUN_ARGS:-}" ]] && read -r -a run_args <<< "$CCHECK_RUN_ARGS"

    if [[ "${CCHECK_LEAKS_MODE:-atexit}" == dylib ]]; then
        check_leaks_setup || return 1
        info "DYLD_INSERT_LIBRARIES=$LEAKS_DYLIB $binary"
        MallocStackLogging=1 DYLD_INSERT_LIBRARIES="$LEAKS_DYLIB" \
            "$binary" ${run_args[@]+"${run_args[@]}"} </dev/null || status=$?
    else
        info "leaks --atExit -- $binary"
        MallocStackLogging=1 leaks --atExit -- "$binary" \
            ${run_args[@]+"${run_args[@]}"} </dev/null || status=$?
    fi

    if (( status == 0 )); then
        ok 'leaks: утечек не обнаружено'; return 0
    fi
    fail "leaks обнаружил утечки или программа упала (код $status)."
    return 1
}

run_valgrind() {
    head1 'valgrind (Linux)'
    need_tool valgrind || return 1
    local binary; binary="$(resolve_binary "${1:-}")"
    local -a run_args=()

    [[ -x "$binary" ]] || { fail "Нет исполняемого файла '$binary'. Сначала собери программу."; return 1; }
    [[ "$binary" == *asan* ]] && warn 'Бинарник собран с ASan — valgrind с ним конфликтует.'
    [[ -n "${CCHECK_RUN_ARGS:-}" ]] && read -r -a run_args <<< "$CCHECK_RUN_ARGS"

    info "valgrind --tool=memcheck --leak-check=yes $binary"
    if valgrind --tool=memcheck --leak-check=yes --show-leak-kinds=all \
        --track-origins=yes --errors-for-leak-kinds=definite,indirect \
        --error-exitcode=1 "$binary" ${run_args[@]+"${run_args[@]}"} </dev/null; then
        ok 'valgrind: ошибок памяти не найдено'
        return 0
    fi
    fail 'valgrind обнаружил проблемы с памятью.'
    return 1
}

# Автовыбор инструмента по ОС: на macOS valgrind фактически не работает.
run_memcheck() {
    if [[ "$OS_NAME" == Darwin ]]; then
        if command -v leaks >/dev/null 2>&1; then
            run_leaks "${1:-}"; return $?
        fi
        warn 'leaks недоступен — проверка памяти пропущена.'; return 0
    fi
    if command -v valgrind >/dev/null 2>&1; then
        run_valgrind "${1:-}"; return $?
    fi
    warn 'valgrind не установлен — проверка памяти пропущена.'
    return 0
}

# ASan намеренно запускается отдельно от leaks/valgrind: они конфликтуют.
run_asan() {
    compile_project asan || return 1
    head1 'AddressSanitizer'
    ASAN_OPTIONS="detect_leaks=1:abort_on_error=0" run_program "$BUILT_BINARY"
}

# ------------------------------------------------------------------- Makefile

run_makefile_check() {
    head1 'Makefile'
    local makefile='Makefile'
    [[ -f "${CCHECK_SOURCE:-.}/Makefile" ]] && makefile="${CCHECK_SOURCE:-.}/Makefile"
    if [[ ! -f "$makefile" ]]; then
        warn 'Makefile не найден (для части проектов Школы 21 он обязателен).'
        return 0
    fi
    need_tool make || return 1

    local target failed=0
    for target in all clean rebuild test; do
        if make -f "$makefile" -n "$target" >/dev/null 2>&1; then
            ok "цель '$target' определена"
        else
            warn "в Makefile нет цели '$target'"
            failed=1
        fi
    done
    (( failed == 0 ))
    return 0
}

# --------------------------------------------------------------------- сборка

collect_sources() {
    local target="${CCHECK_SOURCE:-.}"
    local -a found=()
    local file

    if [[ -f "$target" ]]; then
        case "$target" in
            *.c|*.h|*.cc|*.cpp|*.cxx|*.hpp|*.hh|*.hxx) found+=("$target") ;;
            *) fail "Неподдерживаемое расширение: $target"; return 1 ;;
        esac
    elif [[ -d "$target" ]]; then
        while IFS= read -r -d '' file; do
            found+=("$file")
        done < <(find "$target" \
            \( -type d \( -name .git -o -name build -o -name 'cmake-build-*' \
                          -o -name node_modules -o -name report \) -prune \) -o \
            \( -type f \( -name '*.c' -o -name '*.h' -o -name '*.cc' \
                          -o -name '*.cpp' -o -name '*.cxx' -o -name '*.hpp' \
                          -o -name '*.hh' -o -name '*.hxx' \) -print0 \) | sort -z)
    else
        fail "Путь не существует: $target"; return 1
    fi

    if (( ${#found[@]} == 0 )); then
        fail "Исходники C/C++ не найдены в '$target'."; return 1
    fi
    SOURCES=("${found[@]}")
    info "Найдено исходников: ${#SOURCES[@]}"
}

doctor() {
    head1 'Окружение'
    printf 'ОС: %s\n' "$OS_NAME"
    local tool
    for tool in gcc g++ make cppcheck valgrind leaks timeout; do
        if command -v "$tool" >/dev/null 2>&1; then
            ok "$tool: $(command -v "$tool")"
        else
            warn "$tool: не найден"
        fi
    done
    if find_clang_format; then ok 'clang-format доступен'; fi
    [[ "$OS_NAME" == Darwin ]] && { [[ -e "$LEAKS_DYLIB" ]] && ok "$LEAKS_DYLIB на месте" || check_leaks_setup; }
    return 0
}

# ---------------------------------------------------------------- сценарии

run_full_test() {
    # Fail-fast: первая же ошибка останавливает цепочку.
    run_format_check || return 1
    run_cppcheck     || return 1
    run_makefile_check
    run_format_fix      || return  1
    compile_project normal || return 1
    run_program      || return 1
    run_memcheck     || return 1
    return 0
}

run_basic_test() {
    run_format_check || return 1
    run_cppcheck     || return 1
    return 0
}

show_menu() {
    cat <<MENU

${BOLD}========== C CHECKER (School 21) ==========${NC}
 1. Полное тестирование: формат + cppcheck + Makefile + сборка + запуск + память
 2. Обычное тестирование: формат + cppcheck (без компиляции)
 3. Только clang-format (проверка)
 4. Только cppcheck
 5. Компиляция (-Wall -Werror -Wextra -std=c11) + запуск
 6. AddressSanitizer: компиляция с -fsanitize=address + запуск
 7. Проверка памяти: leaks (macOS) / valgrind (Linux)
 8. Исправить форматирование (clang-format -i)
 9. Проверка Makefile (all / clean / rebuild / test)
10. Диагностика окружения
 0. Выход

Подсказка: ${BOLD}$SCRIPT_NAME 1 src/main.c${NC} — сразу нужный пункт для файла или каталога.
MENU
}

main() {
    local choice="${1:-}"
    local result=0

    if [[ -n "${2:-}" ]]; then
        CCHECK_SOURCE="$2"; export CCHECK_SOURCE
    fi

    if [[ -z "$choice" ]]; then
        show_menu
        read -r -p 'Выбери пункт: ' choice || exit 1
    fi

    [[ "$choice" == 0 ]] && exit 0

    case "$choice" in
        1|2|3|4|5|6|8) collect_sources || { summary || true; exit 1; } ;;
        7|9|10) ;;
        *) fail "Неизвестный пункт: $choice"; show_menu; exit 2 ;;
    esac

    case "$choice" in
        1)  run_full_test       || result=1 ;;
        2)  run_basic_test      || result=1 ;;
        3)  run_format_check    || result=1 ;;
        4)  run_cppcheck        || result=1 ;;
        5)  { compile_project normal && run_program; } || result=1 ;;
        6)  run_asan            || result=1 ;;
        7)  run_memcheck        || result=1 ;;
        8)  run_format_fix      || result=1 ;;
        9)  run_makefile_check  || result=1 ;;
        10) doctor ;;
    esac

    [[ -n "$GENERATED_CONFIG" ]] && info "Создан конфиг $GENERATED_CONFIG — закоммить его в репозиторий или удали."
    summary || result=1
    exit "$result"
}

main "$@"
