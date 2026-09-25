# Функция для установки sing-box вместе с Cronet
install_sing_box() {
    # Проверяем архитектуру до изменения текущей установки и временных файлов.
    case "$architecture" in
        "arm64-v8a")
            ;;
        "mips32le")
            # TODO: Добавить установку mips32le после поддержки sing-box + Naive.
            echo -e "  ${red}Ошибка${reset}: mips32le не поддерживается для sing-box + Naive"
            return 1
            ;;
        "mips32")
            # TODO: Добавить установку mips32 после поддержки sing-box + Naive.
            echo -e "  ${red}Ошибка${reset}: mips32 не поддерживается для sing-box + Naive"
            return 1
            ;;
        *)
            echo -e "  ${red}Ошибка${reset}: Архитектура '$architecture' не поддерживается для sing-box + Naive"
            return 1
            ;;
    esac

    echo -e "  ${yellow}Выполняется установка${reset} sing-box. Пожалуйста, подождите..."

    # Определение переменных
    local sing_box_archive="$tmp_ram/sing-box.tar.gz"
    local stmp_dir="$tmp_dir/sing-box"
    local bin_target="$install_dir/sing-box"
    local cronet_target="/opt/lib/libcronet.so"
    local elf_interpreter="/opt/lib/ld-linux-aarch64.so.1"
    local current_interpreter
    local bin_source cronet_source file elf_magic sz
    local install_err="$stmp_dir/install.err.$$"
    local install_error="" _err
    local bin_backed_up=false cronet_backed_up=false replace_started=false
    local rollback_failed=false

    if [ ! -f "$sing_box_archive" ]; then
        echo -e "  ${red}Ошибка${reset}: Архив sing-box не найден в '$tmp_ram'"
        return 1
    fi
    if [ ! -f "$elf_interpreter" ]; then
        echo -e "  ${red}Ошибка${reset}: Загрузчик Entware '$elf_interpreter' не найден"
        return 1
    fi

    # patchelf требуется только для установки sing-box на поддерживаемой архитектуре.
    if [ "$info_packages_patchelf" != "installed" ]; then
        if ! install_packages "$info_packages_patchelf" "patchelf"; then
            echo -e "  ${red}Ошибка${reset}: Не удалось установить patchelf"
            return 1
        fi
    fi
    if ! command -v patchelf >/dev/null 2>&1; then
        echo -e "  ${red}Ошибка${reset}: patchelf недоступен после установки"
        return 1
    fi
    info_packages_patchelf="installed"

    if ! rm -rf "$stmp_dir" || ! mkdir -p "$stmp_dir"; then
        echo -e "  ${red}Ошибка${reset}: Не удалось подготовить временную директорию '$stmp_dir'"
        return 1
    fi

    # Любая ошибка ведёт к общей обработке и откату обоих компонентов.
    while :; do
        if ! tar -xzf "$sing_box_archive" -C "$stmp_dir" 2>"$install_err"; then
            install_error="Не удалось распаковать архив sing-box"
            break
        fi

        # Имя каталога релиза зависит от версии; принимаем только одну пару файлов.
        if ! bin_source="$(find "$stmp_dir" -type f -name sing-box 2>"$install_err")" ||
           ! cronet_source="$(find "$stmp_dir" -type f -name libcronet.so 2>"$install_err")"; then
            install_error="Не удалось найти компоненты sing-box в распакованном архиве"
            break
        fi
        if [ ! -f "$bin_source" ] || [ ! -s "$bin_source" ]; then
            install_error="Бинарный файл sing-box отсутствует, пуст или неоднозначен в архиве"
            break
        fi
        if [ ! -f "$cronet_source" ] || [ ! -s "$cronet_source" ]; then
            install_error="Файл libcronet.so отсутствует, пуст или неоднозначен в архиве"
            break
        fi
        if [ "${bin_source%/*}" != "${cronet_source%/*}" ]; then
            install_error="sing-box и libcronet.so должны находиться в одном каталоге релиза"
            break
        fi

        # Проверяем оба компонента до создания бэкапов текущей установки.
        for file in "$bin_source" "$cronet_source"; do
            elf_magic="$(hexdump -n 4 -e '4/1 "%02x"' "$file" 2>/dev/null)"
            if [ "$elf_magic" != "7f454c46" ]; then
                install_error="Распакованный файл ${file##*/} не является ELF-файлом (повреждён или не докачан)"
                break
            fi
            # Как и для Xray/Mihomo, отсекаем явно обрезанные файлы меньше 1 MB.
            sz="$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')"
            case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
            if [ "$sz" -lt 1048576 ]; then
                install_error="Распакованный файл ${file##*/} подозрительно мал (${sz} B) — вероятно, обрезан"
                break
            fi
        done
        [ -z "$install_error" ] || break

        # Официальный Linux arm64 ELF должен использовать загрузчик Entware.
        # Проверяем и исправляем только распакованный бинарник до бэкапа пары.
        if ! current_interpreter="$(patchelf --print-interpreter "$bin_source" 2>"$install_err")"; then
            install_error="Не удалось прочитать ELF-интерпретатор sing-box с помощью patchelf"
            break
        fi
        if [ "$current_interpreter" != "$elf_interpreter" ]; then
            if ! patchelf --set-interpreter "$elf_interpreter" "$bin_source" 2>"$install_err"; then
                install_error="Не удалось установить ELF-интерпретатор sing-box '$elf_interpreter'"
                break
            fi
        fi
        if ! current_interpreter="$(patchelf --print-interpreter "$bin_source" 2>"$install_err")"; then
            install_error="Не удалось повторно прочитать ELF-интерпретатор sing-box после проверки patchelf"
            break
        fi
        if [ "$current_interpreter" != "$elf_interpreter" ]; then
            install_error="ELF-интерпретатор sing-box '$current_interpreter' не совпадает с '$elf_interpreter'"
            break
        fi
        if ! chmod +x "$bin_source" 2>"$install_err"; then
            install_error="Не удалось установить права на выполнение распакованного sing-box"
            break
        fi
        if ! LD_LIBRARY_PATH=/opt/lib "$bin_source" version >"$install_err" 2>&1; then
            install_error="Распакованный sing-box не запускается с загрузчиком Entware и LD_LIBRARY_PATH=/opt/lib"
            break
        fi

        # Не затираем бэкапы, оставшиеся после неудачного восстановления.
        for file in "$bin_target" "$cronet_target"; do
            if [ -e "$file" ] && [ ! -f "$file" ]; then
                install_error="Путь '$file' занят не обычным файлом"
                break
            fi
            if [ -e "${file}_bak" ] || [ -L "${file}_bak" ]; then
                install_error="Уже существует бэкап '${file}_bak'; восстановите или удалите его перед установкой"
                break
            fi
        done
        [ -z "$install_error" ] || break

        if ! mkdir -p /opt/lib 2>"$install_err"; then
            install_error="Не удалось создать директорию /opt/lib"
            break
        fi

        if [ -e "$bin_target" ] || [ -L "$bin_target" ]; then
            if ! mv "$bin_target" "${bin_target}_bak" 2>"$install_err"; then
                install_error="Не удалось создать бэкап sing-box"
                break
            fi
            bin_backed_up=true
        fi
        if [ -e "$cronet_target" ] || [ -L "$cronet_target" ]; then
            if ! mv "$cronet_target" "${cronet_target}_bak" 2>"$install_err"; then
                install_error="Не удалось создать бэкап libcronet.so"
                break
            fi
            cronet_backed_up=true
        fi

        # С этого момента при откате удаляем и частично записанные новые файлы.
        replace_started=true
        if ! mv "$bin_source" "$bin_target" 2>"$install_err"; then
            install_error="Не удалось переместить sing-box в $install_dir"
            break
        fi
        if ! mv "$cronet_source" "$cronet_target" 2>"$install_err"; then
            install_error="Не удалось переместить libcronet.so в /opt/lib"
            break
        fi
        if ! chmod +x "$bin_target" 2>"$install_err"; then
            install_error="Не удалось установить права на выполнение sing-box"
            break
        fi

        # Финальная проверка установленной пары с новой библиотекой Cronet.
        if [ ! -x "$bin_target" ] || ! LD_LIBRARY_PATH=/opt/lib "$install_dir/sing-box" version >"$install_err" 2>&1; then
            install_error="Установленный sing-box не запускается с libcronet.so (повреждён или несовместим с архитектурой)"
            break
        fi
        break
    done

    if [ -n "$install_error" ]; then
        _err="$(cat "$install_err" 2>/dev/null)"
        echo -e "  ${red}Ошибка${reset}: $install_error"
        [ -n "$_err" ] && echo -e "  Подробности: $_err"
        case "$_err" in
            *"No space left"*|*"ENOSPC"*|*"места"*)
                echo -e "  ${yellow}Недостаточно свободного места${reset} на разделе с $install_dir или /opt/lib"
                ;;
        esac

        # Сначала убираем ОБА новых компонента, затем восстанавливаем прежнюю пару.
        # Если сбой произошёл при бэкапе, ещё не перемещённый оригинал не трогаем.
        if [ "$replace_started" = true ]; then
            for file in "$bin_target" "$cronet_target"; do
                if ! rm -f "$file"; then
                    echo -e "  ${red}Ошибка отката${reset}: Не удалось удалить '$file'"
                    rollback_failed=true
                fi
            done
        fi
        if [ "$bin_backed_up" = true ]; then
            if ! mv "${bin_target}_bak" "$bin_target"; then
                echo -e "  ${red}Ошибка отката${reset}: Не удалось восстановить sing-box из '${bin_target}_bak'"
                rollback_failed=true
            fi
        fi
        if [ "$cronet_backed_up" = true ]; then
            if ! mv "${cronet_target}_bak" "$cronet_target"; then
                echo -e "  ${red}Ошибка отката${reset}: Не удалось восстановить libcronet.so из '${cronet_target}_bak'"
                rollback_failed=true
            fi
        fi
        if [ "$replace_started" = true ] || [ "$bin_backed_up" = true ] || [ "$cronet_backed_up" = true ]; then
            if [ "$rollback_failed" = false ]; then
                echo -e "  ${yellow}Восстановлено${reset} предыдущее состояние sing-box и libcronet.so"
            else
                echo -e "  ${red}Откат не завершён${reset}: Требуется ручное восстановление из оставшихся файлов _bak"
            fi
        fi
        rm -f "$sing_box_archive"
        rm -rf "$stmp_dir"
        return 1
    fi

    # Пара успешно проверена; удаляем более не нужные бэкапы и временные файлы.
    if ! rm -f "${bin_target}_bak" "${cronet_target}_bak" "$sing_box_archive" || ! rm -rf "$stmp_dir"; then
        echo -e "  ${yellow}Предупреждение${reset}: Не удалось удалить все временные файлы установки sing-box"
    fi
    echo -e "  sing-box и libcronet.so ${green}успешно установлены${reset}"
    return 0
}
