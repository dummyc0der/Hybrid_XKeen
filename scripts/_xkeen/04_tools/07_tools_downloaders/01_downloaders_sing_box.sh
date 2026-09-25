# Проверить архитектуру до запросов к сети и изменения файлов/переменных.
_sing_box_check_architecture() {
    case "$architecture" in
        "arm64-v8a")
            return 0
            ;;
        "mips32le")
            # TODO: Добавить загрузку mips32le после поддержки sing-box + Naive.
            printf "  ${red}Ошибка${reset}: mips32le намеренно не поддерживается для Hybrid_XKeen sing-box + Naive (этап 2.1)\n"
            return 1
            ;;
        "mips32")
            # TODO: Добавить загрузку mips32 после поддержки sing-box + Naive.
            printf "  ${red}Ошибка${reset}: mips32 намеренно не поддерживается для Hybrid_XKeen sing-box + Naive (этап 2.1)\n"
            return 1
            ;;
        *)
            # TODO: Добавлять архитектуры только с проверенной поддержкой Naive.
            printf "  ${red}Ошибка${reset}: Архитектура %s не поддерживается для Hybrid_XKeen sing-box + Naive\n" "$architecture"
            return 1
            ;;
    esac
}

# Сформировать download_url и extension для указанной версии sing-box.
# $1 = version_selected (например v1.13.0)
# Устанавливает глобальные переменные: download_url, filename, extension
# Возврат: 0 — успех, 1 — неподдерживаемая архитектура или пустая версия
_sing_box_build_url() {
    _sing_box_check_architecture || return 1
    local version="${1#v}"
    if [ -z "$version" ]; then
        printf "  ${red}Ошибка${reset}: Версия sing-box не может быть пустой\n"
        return 1
    fi

    # Только официальный Linux arm64 архив с sing-box и libcronet.so.
    filename="sing-box-$version-linux-arm64.tar.gz"
    download_url="${sing_box_tar_url}/v$version/$filename"
    extension="tar.gz"
    return 0
}

# Проверить целостность архива и наличие обоих компонентов без распаковки.
_sing_box_validate_archive() {
    local archive_entries
    archive_entries=$(tar -tzf "$1" 2>/dev/null) || return 1
    printf '%s\n' "$archive_entries" | awk -F/ '
        $NF == "sing-box" { binary = 1 }
        $NF == "libcronet.so" { cronet = 1 }
        END { exit !(binary && cronet) }
    '
}

# Функция для проверки и загрузки выбранной версии sing-box.
# $1 = version_selected. Установка компонентов выполняется отдельно.
_sing_box_perform_install() {
    _sing_box_build_url "$1" || return 1
    local version="$1"
    mkdir -p "$tmp_ram" || return 1

    if ! _network_probe "$download_url" "версии sing-box $version"; then
        return 1
    fi

    printf "  ${yellow}Выполняется загрузка${reset} sing-box %s\n" "$version"
    if ! _network_download "$download_url" "$tmp_ram/sing-box.tar.gz" "sing-box" "$max_attempts" "$delay"; then
        return 1
    fi

    if ! _sing_box_validate_archive "$tmp_ram/sing-box.tar.gz"; then
        printf "  ${red}Ошибка${reset}: Архив sing-box повреждён или не содержит sing-box и libcronet.so; требуется сборка с Naive\n"
        rm -f "$tmp_ram/sing-box.tar.gz"
        return 1
    fi

    printf "  sing-box ${green}успешно загружен${reset}\n"
    return 0
}

# Загрузка sing-box
download_sing_box() {
    _sing_box_check_architecture || return 1
    if [ "$autoinstall_mode" != "true" ] || [ "$sing_box_release_policy" = "latest" ]; then
        USE_JSDELIVR=""
        printf "\n  ${green}Запрос информации${reset} о релизах ${yellow}sing-box${reset}\n"
        fetch_release_tags "$sing_box_api_url" "$sing_box_jsd_url" "10"
        # sing-box: оставляем только стабильные теги GitHub и версии jsDelivr.
        if ! RELEASE_TAGS=$(printf '%s\n' "$RELEASE_TAGS" | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$'); then
            printf "  ${red}Ошибка${reset}: В списке релизов sing-box нет стабильной версии\n"
            return 1
        fi
    fi

    # --- АВТОМАТИЧЕСКИЙ РЕЖИМ ---
    if [ "$autoinstall_mode" = "true" ]; then
        case "$sing_box_release_policy" in
            "validated")
                version_selected="$sing_box_validated_version"
                ;;
            "latest")
                # Для latest выбираем первый стабильный тег.
                version_selected=$(echo "$RELEASE_TAGS" | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
                if [ -z "$version_selected" ]; then
                    printf "  ${red}Ошибка${reset}: В списке релизов sing-box нет стабильной версии\n"
                    return 1
                fi
                [ "$USE_JSDELIVR" = "true" ] && version_selected="v$version_selected"
                ;;
            *)
                printf "  ${red}Ошибка${reset}: Неизвестная политика релизов sing-box: %s (допустимы validated | latest)\n" "$sing_box_release_policy"
                return 1
                ;;
        esac
        printf "  ${green}Авто-режим${reset}: выбрана версия ${yellow}%s${reset} (политика: %s)\n" "$version_selected" "$sing_box_release_policy"

        _sing_box_perform_install "$version_selected"
        return $?
    fi

    # --- ИНТЕРАКТИВНЫЙ РЕЖИМ ---
    while true; do
        echo
        echo "$RELEASE_TAGS" | awk '{printf "    %2d. %s\n", NR, $0}'
        echo
        echo "     9. Ручной ввод версии"
        echo
        echo "     0. Пропустить загрузку sing-box"

        printf "\n  Введите порядковый номер релиза (0 - пропустить, 9 - ручной ввод): "
        read -r choice || return 1

        case "$choice" in
            [0-9]) ;;
            *)
                printf "  ${red}Некорректный${reset} ввод. Пожалуйста, введите число\n"
                sleep 1
                continue
                ;;
        esac

        if [ "$choice" = "0" ]; then
            bypass_sing_box="true"
            printf "  Загрузка sing-box ${yellow}пропущена${reset}\n"
            return 0
        fi

        if [ "$choice" = "9" ]; then
            printf "  Введите версию sing-box для загрузки (например: v1.13.0): "
            read -r version_selected || return 1
            if [ -z "$version_selected" ]; then
                printf "  ${red}Ошибка${reset}: Версия не может быть пустой\n"
                sleep 1
                continue
            fi
            version_selected=$(echo "$version_selected" | sed 's/^v//')
            version_selected="v$version_selected"
        else
            version_selected=$(echo "$RELEASE_TAGS" | awk -v line="$choice" 'NR == line {print $0; exit}')
            if [ -z "$version_selected" ]; then
                printf "  Выбранный номер ${red}вне диапазона.${reset} Пожалуйста, попробуйте снова\n"
                sleep 1
                continue
            fi
            [ "$USE_JSDELIVR" = "true" ] && version_selected="v$version_selected"
        fi

        if _sing_box_perform_install "$version_selected"; then
            return 0
        fi
    done
}
