#!/bin/sh
# Run with: sh test/sing_box_install_test.sh
# Isolated control-flow fixtures: patchelf and the ARM64 executable are simulated.
# Real tar/file operations exercise validation, replacement and paired rollback.
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
temp_parent=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
fixture_root=$(mktemp -d "$temp_parent/xkeen-sing-box-test.XXXXXX")
cleanup() {
    case "$fixture_root" in
        "$temp_parent"/xkeen-sing-box-test.*) rm -rf -- "$fixture_root" ;;
        *) printf 'Refusing cleanup outside fixture directory: %s\n' "$fixture_root" >&2 ;;
    esac
}
trap cleanup EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail "$case_name: missing '$2' in $1"; }
assert_absent() { if grep -F -- "$2" "$1" >/dev/null; then fail "$case_name: unexpected '$2' in $1"; fi; }

# Redirect only filesystem access to /opt/lib; retain the real interpreter and
# LD_LIBRARY_PATH strings so the stubs can assert the exact router arguments.
sed \
    -e 's|"/opt/lib/libcronet.so"|"$fixture_lib/libcronet.so"|g' \
    -e 's|\[ ! -f "$elf_interpreter" \]|[ ! -f "$fixture_lib/ld-linux-aarch64.so.1" ]|' \
    -e 's|mkdir -p /opt/lib|mkdir -p "$fixture_lib"|' \
    "$repo_dir/scripts/_xkeen/02_install/02_install_sing_box.sh" > "$fixture_root/installer.sh"

# Use the real shared package helper with a separate opkg cache per fixture.
sed 's|/tmp/.xkeen_opkg_updated|$case_dir/opkg-updated|g' \
    "$repo_dir/scripts/_xkeen/02_install/01_install_packages.sh" > "$fixture_root/packages.sh"
common_packages_installed() {
    info_packages_curl=installed info_packages_jq=installed info_packages_ip_full=installed
    info_packages_iptables=installed info_packages_ipset=installed info_packages_cabundle=installed
    info_packages_uname=installed info_packages_nohup=installed
}

mkdir -p "$fixture_root/template/release"
cat > "$fixture_root/template/release/sing-box" <<'BINARY'
#!/bin/sh
set -eu
[ "$#" -eq 1 ] && [ "$1" = version ] || exit 71
[ "${LD_LIBRARY_PATH:-}" = /opt/lib ] || exit 72
[ "$(cat "$case_dir/interpreter")" = /opt/lib/ld-linux-aarch64.so.1 ] || exit 73
if [ "$0" = "$install_dir/sing-box" ]; then
    printf 'installed-version\n' >> "$events"
    cmp "$fixture_lib/libcronet.so" "$case_dir/new-cronet" || exit 74
    [ "$case_name" != final_version_failure ] || exit 75
else
    printf 'extracted-version\n' >> "$events"
    [ "$case_name" != extracted_version_failure ] || exit 76
fi
printf 'sing-box version fixture\n'
exit 0
BINARY
# Keep the actual >= 1 MiB size check active for both components.
dd if=/dev/zero bs=1048576 count=1 2>/dev/null | tr '\000' '#' >> "$fixture_root/template/release/sing-box"
printf '\n' >> "$fixture_root/template/release/sing-box"
chmod +x "$fixture_root/template/release/sing-box"
printf '\177ELFnew-cronet\n' > "$fixture_root/template/release/libcronet.so"
dd if=/dev/zero bs=1048576 count=1 2>/dev/null >> "$fixture_root/template/release/libcronet.so"

run_case() (
    case_name=$1
    expected=$2
    case_dir="$fixture_root/$case_name"
    fixture_lib="$case_dir/opt/lib"
    install_dir="$case_dir/opt/sbin"
    tmp_ram="$case_dir/ram"
    tmp_dir="$case_dir/tmp"
    events="$case_dir/events"
    architecture=arm64-v8a
    common_packages_installed
    info_packages_patchelf=installed
    case "$case_name" in
        missing_archive|missing_loader|install_missing_patchelf|patchelf_install_failure|patchelf_unavailable_after_install|mips32le|mips32|other_arch)
            info_packages_patchelf=not_installed
            ;;
    esac
    red= reset= yellow= green=
    export case_name case_dir fixture_lib install_dir events
    mkdir -p "$fixture_lib" "$install_dir" "$tmp_ram" "$tmp_dir" "$case_dir/archive"
    : > "$events"
    : > "$fixture_lib/ld-linux-aarch64.so.1"
    printf 'old-sing-box\n' > "$install_dir/sing-box"
    printf 'old-cronet\n' > "$fixture_lib/libcronet.so"
    cp "$install_dir/sing-box" "$case_dir/old-bin"
    cp "$fixture_lib/libcronet.so" "$case_dir/old-cronet"
    cp -R "$fixture_root/template/release" "$case_dir/archive/release"
    cp "$case_dir/archive/release/libcronet.so" "$case_dir/new-cronet"
    printf '/lib/ld-linux-aarch64.so.1\n' > "$case_dir/interpreter"
    printf '0\n' > "$case_dir/print-count"

    case "$case_name" in
        already_correct) printf '/opt/lib/ld-linux-aarch64.so.1\n' > "$case_dir/interpreter" ;;
        missing_loader) rm "$fixture_lib/ld-linux-aarch64.so.1" ;;
        missing_cronet) rm "$case_dir/archive/release/libcronet.so" ;;
        invalid_cronet) printf 'invalid-cronet\n' > "$case_dir/archive/release/libcronet.so" ;;
        truncated_cronet) printf '\177ELF\n' > "$case_dir/archive/release/libcronet.so" ;;
        stale_backup) printf 'preserved-backup\n' > "$install_dir/sing-box_bak" ;;
        fresh_install|fresh_rollback) rm "$install_dir/sing-box" "$fixture_lib/libcronet.so" ;;
        mips32le|mips32|other_arch) architecture=$case_name ;;
    esac
    if [ "$case_name" != missing_archive ]; then
        tar -czf "$tmp_ram/sing-box.tar.gz" -C "$case_dir/archive" release
    fi
    case "$case_name" in
        missing_archive|missing_loader)
            mkdir -p "$tmp_dir/sing-box"
            printf 'preserved-temp\n' > "$tmp_dir/sing-box/preexisting"
            ;;
    esac

    # The executable fixture is a shell script; simulate only its ELF magic.
    # Cronet's magic and both component sizes are read from the actual files.
    hexdump() {
        case "$5" in
            */sing-box)
                if [ "$case_name" = invalid_binary ]; then printf '00000000'; else printf '7f454c46'; fi
                ;;
            *) od -An -N4 -tx1 "$5" | tr -d '[:space:]' ;;
        esac
    }
    fixture_patchelf() {
            case "$1" in
                --print-interpreter)
                    [ "$#" -eq 2 ] && [ "$2" = "$tmp_dir/sing-box/release/sing-box" ] || return 81
                    print_count=$(cat "$case_dir/print-count")
                    print_count=$((print_count + 1))
                    printf '%s\n' "$print_count" > "$case_dir/print-count"
                    printf 'print-interpreter\n' >> "$events"
                    if [ "$case_name" = initial_print_failure ] && [ "$print_count" -eq 1 ]; then
                        printf 'fixture print failure\n' >&2
                        return 82
                    fi
                    if [ "$case_name" = verification_print_failure ] && [ "$print_count" -eq 2 ]; then
                        printf 'fixture verification failure\n' >&2
                        return 83
                    fi
                    cat "$case_dir/interpreter"
                    ;;
                --set-interpreter)
                    [ "$#" -eq 3 ] && [ "$2" = /opt/lib/ld-linux-aarch64.so.1 ] &&
                        [ "$3" = "$tmp_dir/sing-box/release/sing-box" ] || return 84
                    printf 'set-interpreter\n' >> "$events"
                    if [ "$case_name" = patch_failure ]; then
                        printf 'fixture patch failure\n' >&2
                        return 85
                    fi
                    if [ "$case_name" != verification_mismatch ]; then
                        printf '%s\n' "$2" > "$case_dir/interpreter"
                    fi
                    ;;
                *) return 86 ;;
            esac
    }
    case "$case_name" in
        missing_archive|missing_loader|missing_patchelf|install_missing_patchelf|patchelf_install_failure|patchelf_unavailable_after_install)
            # Require a genuinely absent command, not a stub returning failure.
            if command -v patchelf >/dev/null 2>&1; then
                mkdir -p "$case_dir/path"
                for utility in rm mkdir tar gzip find wc tr cat od chmod mv cmp touch; do
                    ln -s "$(command -v "$utility")" "$case_dir/path/$utility"
                done
                saved_path=$PATH
                PATH="$case_dir/path"
            fi
            ;;
        *) patchelf() { fixture_patchelf "$@"; } ;;
    esac
    opkg() {
        printf 'opkg %s\n' "$*" >> "$events"
        case "$*" in
            update) return 0 ;;
            'install patchelf')
                [ "$case_name" != patchelf_install_failure ] || return 91
                if [ "$case_name" != patchelf_unavailable_after_install ]; then
                    patchelf() { fixture_patchelf "$@"; }
                fi
                ;;
            *) return 92 ;;
        esac
    }
    mv() {
        printf 'mv %s -> %s\n' "$1" "$2" >> "$events"
        case "$case_name:$1:$2" in
            "bin_backup_failure:$install_dir/sing-box:$install_dir/sing-box_bak"|\
            "cronet_backup_failure:$fixture_lib/libcronet.so:$fixture_lib/libcronet.so_bak"|\
            "bin_replace_failure:$tmp_dir/sing-box/release/sing-box:$install_dir/sing-box")
                printf 'fixture move failure\n' >&2
                return 87
                ;;
            "cronet_replace_failure:$tmp_dir/sing-box/release/libcronet.so:$fixture_lib/libcronet.so"|\
            "fresh_rollback:$tmp_dir/sing-box/release/libcronet.so:$fixture_lib/libcronet.so")
                printf 'partial-new-cronet\n' > "$2"
                printf 'fixture partial move failure\n' >&2
                return 88
                ;;
        esac
        command mv "$@"
    }
    chmod() {
        if [ "$case_name" = extracted_chmod_failure ] && [ "$2" = "$tmp_dir/sing-box/release/sing-box" ]; then
            return 89
        fi
        if [ "$case_name" = installed_chmod_failure ] && [ "$2" = "$install_dir/sing-box" ]; then
            return 90
        fi
        command chmod "$@"
    }
    . "$fixture_root/packages.sh"
    . "$fixture_root/installer.sh"
    if install_sing_box > "$case_dir/result.log" 2>&1; then rc=0; else rc=$?; fi
    if [ "${saved_path+x}" = x ]; then PATH=$saved_path; fi
    case "$case_name" in
        install_missing_patchelf|patchelf_install_failure|patchelf_unavailable_after_install)
            assert_contains "$events" 'opkg update'
            [ "$(grep -c '^opkg install patchelf$' "$events")" -eq 1 ] || fail "$case_name: expected one package install"
            ;;
        *) assert_absent "$events" 'opkg ' ;;
    esac
    if [ "$expected" = success ]; then
        [ "$rc" -eq 0 ] || { cat "$case_dir/result.log"; fail "$case_name: rc=$rc"; }
        [ "$info_packages_patchelf" = installed ] || fail "$case_name: stale package state"
        cmp "$fixture_root/template/release/sing-box" "$install_dir/sing-box" || fail "$case_name: wrong installed binary"
        cmp "$case_dir/new-cronet" "$fixture_lib/libcronet.so" || fail "$case_name: wrong installed Cronet"
        [ "$(cat "$case_dir/print-count")" -eq 2 ] || fail "$case_name: missing interpreter recheck"
        [ "$(cat "$case_dir/interpreter")" = /opt/lib/ld-linux-aarch64.so.1 ] || fail "$case_name: wrong interpreter"
        assert_contains "$events" extracted-version
        assert_contains "$events" installed-version
        if [ "$case_name" = already_correct ]; then
            assert_absent "$events" set-interpreter
        else
            assert_contains "$events" set-interpreter
        fi
        # Interpreter recheck and extracted execution must precede any backup.
        awk '/print-interpreter/ { checks++ } /extracted-version/ { validated=1 }
             /^mv / { if (checks != 2 || !validated) exit 1 }' "$events" || fail "$case_name: early replacement"
    else
        [ "$rc" -ne 0 ] || fail "$case_name: installation unexpectedly succeeded"
        assert_contains "$case_dir/result.log" 'Ошибка'
        if [ "$case_name" = fresh_rollback ]; then
            [ ! -e "$install_dir/sing-box" ] && [ ! -e "$fixture_lib/libcronet.so" ] || fail "$case_name: partial new pair remains"
        else
            cmp "$case_dir/old-bin" "$install_dir/sing-box" || fail "$case_name: old binary changed"
            cmp "$case_dir/old-cronet" "$fixture_lib/libcronet.so" || fail "$case_name: old Cronet changed"
        fi
        if [ "$expected" = preflight_failure ]; then
            assert_absent "$events" 'mv '
            assert_absent "$events" installed-version
        fi
        case "$case_name" in
            missing_archive) assert_contains "$case_dir/result.log" 'Архив sing-box не найден' ;;
            missing_loader) assert_contains "$case_dir/result.log" /opt/lib/ld-linux-aarch64.so.1 ;;
            missing_patchelf|patchelf_unavailable_after_install)
                assert_contains "$case_dir/result.log" 'patchelf недоступен после установки'
                ;;
            patchelf_install_failure)
                assert_contains "$case_dir/result.log" 'Не удалось установить patchelf'
                assert_contains "$case_dir/result.log" 'patchelf (opkg rc=91)'
                [ "$info_packages_patchelf" = not_installed ] || fail "$case_name: failed install marked installed"
                ;;
            patch_failure) assert_contains "$case_dir/result.log" 'fixture patch failure' ;;
            initial_print_failure) assert_contains "$case_dir/result.log" 'fixture print failure' ;;
            verification_print_failure) assert_contains "$case_dir/result.log" 'fixture verification failure' ;;
            verification_mismatch) assert_contains "$case_dir/result.log" 'не совпадает' ;;
            extracted_version_failure) assert_contains "$case_dir/result.log" LD_LIBRARY_PATH=/opt/lib ;;
            cronet_backup_failure|bin_replace_failure|cronet_replace_failure|installed_chmod_failure|final_version_failure|fresh_rollback)
                assert_contains "$case_dir/result.log" 'Восстановлено'
                ;;
        esac
    fi
    if [ "$case_name" = stale_backup ]; then
        [ "$(cat "$install_dir/sing-box_bak")" = preserved-backup ] || fail "$case_name: backup overwritten"
    else
        [ ! -e "$install_dir/sing-box_bak" ] || fail "$case_name: binary backup remains"
    fi
    [ ! -e "$fixture_lib/libcronet.so_bak" ] || fail "$case_name: Cronet backup remains"
    case "$case_name" in
        missing_archive|missing_loader)
            [ "$info_packages_patchelf" = not_installed ] || fail "$case_name: package state changed"
            [ "$(cat "$tmp_dir/sing-box/preexisting")" = preserved-temp ] || fail "$case_name: existing temporary directory changed"
            [ ! -s "$events" ] || fail "$case_name: static prerequisite guard bypassed"
            if [ "$case_name" = missing_archive ]; then
                [ ! -e "$tmp_ram/sing-box.tar.gz" ] || fail "$case_name: archive created"
            else
                [ -f "$tmp_ram/sing-box.tar.gz" ] || fail "$case_name: archive removed"
            fi
            ;;
        missing_patchelf|patchelf_install_failure|patchelf_unavailable_after_install|mips32le|mips32|other_arch)
            [ -f "$tmp_ram/sing-box.tar.gz" ] || fail "$case_name: archive touched"
            [ ! -d "$tmp_dir/sing-box" ] || fail "$case_name: extraction started"
            assert_absent "$events" print-interpreter
            assert_absent "$events" extracted-version
            ;;
        *)
            [ ! -e "$tmp_ram/sing-box.tar.gz" ] && [ ! -e "$tmp_dir/sing-box" ] || fail "$case_name: temporary files remain"
            ;;
    esac
    printf 'PASS %s\n' "$case_name"
)

for case_name in patched_install already_correct fresh_install install_missing_patchelf; do
    run_case "$case_name" success
done
for case_name in missing_archive missing_loader missing_patchelf patchelf_install_failure \
    patchelf_unavailable_after_install initial_print_failure patch_failure \
    verification_print_failure verification_mismatch extracted_chmod_failure \
    extracted_version_failure missing_cronet invalid_cronet truncated_cronet \
    invalid_binary stale_backup mips32le mips32 other_arch; do
    run_case "$case_name" preflight_failure
done
for case_name in bin_backup_failure cronet_backup_failure bin_replace_failure \
    cronet_replace_failure installed_chmod_failure final_version_failure fresh_rollback; do
    run_case "$case_name" rollback_failure
done

# Package discovery uses the existing cached opkg list, including exact names.
for package_fixture in installed absent similar_name; do
    (
        case_name="package_$package_fixture"
        opkg() {
            [ "$1" = list-installed ] || return 1
            case "$package_fixture" in
                installed) printf 'patchelf - 0.18\n' ;;
                absent) printf 'curl - 8.0\n' ;;
                similar_name) printf 'patchelf-extra - 0.18\n' ;;
            esac
        }
        . "$repo_dir/scripts/_xkeen/01_info/02_info_packages.sh"
        if [ "$package_fixture" = installed ]; then expected=installed; else expected=not_installed; fi
        [ "$info_packages_patchelf" = "$expected" ] || fail "$case_name: wrong package state"
        printf 'PASS %s\n' "$case_name"
    )
done

# Exercise shared package setup followed by each other core's real installer.
# Only ELF magic and Xray unzip are simulated for the executable shell fixture.
printf '#!/bin/sh\nexit 0\n' > "$fixture_root/other-core"
dd if=/dev/zero bs=1048576 count=1 2>/dev/null | tr '\000' '#' >> "$fixture_root/other-core"
printf '\n' >> "$fixture_root/other-core"
chmod +x "$fixture_root/other-core"
for core in xray mihomo; do
    (
        case_name="${core}_without_patchelf"
        case_dir="$fixture_root/$case_name"
        tmp_ram="$case_dir/ram"
        install_dir="$case_dir/bin"
        xtmp_dir="$case_dir/xray"
        mtmp_dir="$case_dir/mihomo"
        xray_conf_dir="$case_dir/config"
        softfloat=false
        red= reset= yellow= green=
        mkdir -p "$tmp_ram" "$install_dir"
        common_packages_installed
        info_packages_curl=not_installed info_packages_patchelf=not_installed
        package_events="$case_dir/events"
        : > "$package_events"
        opkg() {
            printf '%s\n' "$*" >> "$package_events"
            case "$*" in update|'install curl') return 0 ;; *) return 93 ;; esac
        }
        hexdump() { printf '7f454c46'; }
        unzip() { cp "$fixture_root/other-core" "$xtmp_dir/xray"; }
        if . "$fixture_root/packages.sh" > "$case_dir/result.log" 2>&1; then rc=0; else rc=$?; fi
        [ "$rc" -eq 0 ] || fail "$case_name: shared package setup failed"
        # Importing the sing-box module must not install its dependencies.
        . "$fixture_root/installer.sh"
        . "$repo_dir/scripts/_xkeen/02_install/02_install_$core.sh"
        case "$core" in
            xray)
                : > "$tmp_ram/xray.zip"
                if install_xray >> "$case_dir/result.log" 2>&1; then rc=0; else rc=$?; fi
                ;;
            mihomo)
                gzip -c "$fixture_root/other-core" > "$tmp_ram/mihomo.gz"
                if install_mihomo >> "$case_dir/result.log" 2>&1; then rc=0; else rc=$?; fi
                ;;
        esac
        [ "$rc" -eq 0 ] || { cat "$case_dir/result.log"; fail "$case_name: core install failed"; }
        cmp "$fixture_root/other-core" "$install_dir/$core" || fail "$case_name: wrong installed core"
        assert_contains "$package_events" 'install curl'
        assert_absent "$package_events" patchelf
        [ "$info_packages_patchelf" = not_installed ] || fail "$case_name: sing-box dependency state changed"
        printf 'PASS %s\n' "$case_name"
    )
done
printf 'All 35 fixture tests passed.\n'
