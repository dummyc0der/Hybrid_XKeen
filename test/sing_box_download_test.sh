#!/bin/sh
# Run with: sh test/sing_box_download_test.sh
# Simulate fetched release lists and downloads; exercise real selection/URL logic.
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
temp_parent=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
fixture_root=$(mktemp -d "$temp_parent/xkeen-sing-box-download-test.XXXXXX")
cleanup() {
    case "$fixture_root" in
        "$temp_parent"/xkeen-sing-box-download-test.*) rm -rf -- "$fixture_root" ;;
        *) printf 'Refusing cleanup outside fixture directory: %s\n' "$fixture_root" >&2 ;;
    esac
}
trap cleanup EXIT HUP INT TERM

fail() { printf 'FAIL: %s: %s\n' "$case_name" "$*" >&2; exit 1; }
assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail "missing '$2' in $1"; }
assert_absent() { if grep -F -- "$2" "$1" >/dev/null; then fail "unexpected '$2' in $1"; fi; }

run_case() (
    case_name=$1
    case_dir="$fixture_root/$case_name"
    mkdir -p "$case_dir"
    events="$case_dir/events"
    : > "$events"
    . "$repo_dir/scripts/_xkeen/04_tools/07_tools_downloaders/01_downloaders_sing_box.sh"

    architecture=arm64-v8a
    autoinstall_mode=false
    sing_box_release_policy=validated
    sing_box_validated_version=v1.13.3
    sing_box_api_url=https://api.example.invalid/releases
    sing_box_jsd_url=https://jsdelivr.example.invalid/package
    sing_box_tar_url=https://download.example.invalid/releases/download
    red= reset= yellow= green=
    RELEASE_TAGS=unfetched
    USE_JSDELIVR=stale
    bypass_sing_box=
    provider=jsdelivr
    choice_input=1
    expected_version=v1.14.1
    expected_rc=0
    download_rc=0
    expected_fetch=1
    expected_download=1
    expected_menu=1
    expected_error=
    prerelease_only=false
    case "$case_name" in
        jsdelivr_mixed_first) ;;
        jsdelivr_mixed_second) choice_input=2; expected_version=v1.13.3 ;;
        github_mixed) provider=github ;;
        jsdelivr_prerelease_only|github_prerelease_only|empty_releases)
            prerelease_only=true
            [ "$case_name" != github_prerelease_only ] || provider=github
            expected_rc=1 expected_download=0 expected_menu=0
            expected_error='В списке релизов sing-box нет стабильной версии'
            ;;
        latest_jsdelivr|latest_github|latest_prerelease_only|latest_download_failure)
            autoinstall_mode=true sing_box_release_policy=latest expected_menu=0
            [ "$case_name" != latest_github ] || provider=github
            if [ "$case_name" = latest_prerelease_only ]; then
                prerelease_only=true expected_rc=1 expected_download=0
                expected_error='В списке релизов sing-box нет стабильной версии'
            fi
            if [ "$case_name" = latest_download_failure ]; then download_rc=23 expected_rc=23; fi
            ;;
        validated|validated_download_failure)
            autoinstall_mode=true expected_fetch=0 expected_menu=0
            expected_version=$sing_box_validated_version
            if [ "$case_name" = validated_download_failure ]; then download_rc=23 expected_rc=23; fi
            ;;
        interactive_skip) choice_input=0 expected_download=0 ;;
        interactive_manual) choice_input=$(printf '9\n1.13.3'); expected_version=v1.13.3 ;;
        unknown_policy)
            autoinstall_mode=true sing_box_release_policy=unknown expected_fetch=0
            expected_rc=1 expected_download=0 expected_menu=0
            expected_error='Неизвестная политика релизов sing-box'
            ;;
        mips32le|mips32|unsupported)
            architecture=$case_name expected_fetch=0 expected_rc=1 expected_download=0 expected_menu=0
            expected_error='не поддерживается'
            ;;
        *) fail 'unknown fixture' ;;
    esac

    tag_prefix=
    [ "$provider" != github ] || tag_prefix=v
    fetched_tags=$(printf '%s\n' "${tag_prefix}1.15.0-alpha.8" "${tag_prefix}1.14.1" \
        "${tag_prefix}1.15.0-beta.1" "${tag_prefix}1.13.3" "${tag_prefix}1.15.0-rc.1" \
        "${tag_prefix}1.14.1+build.1" '1x14x2' '1.14' '1.14.1.1' 'nightly')
    expected_tags=$(printf '%s\n' "${tag_prefix}1.14.1" "${tag_prefix}1.13.3")
    if [ "$prerelease_only" = true ]; then
        fetched_tags=$(printf '%s\n' "${tag_prefix}1.15.0-alpha.8" "${tag_prefix}1.15.0-alpha.7")
        expected_tags=
    fi
    [ "$case_name" != empty_releases ] || fetched_tags=

    fetch_release_tags() {
        [ "$#" -eq 3 ] && [ "$1" = "$sing_box_api_url" ] &&
            [ "$2" = "$sing_box_jsd_url" ] && [ "$3" = 10 ] || fail 'fetch arguments changed'
        printf 'fetch\n' >> "$events"
        RELEASE_TAGS=$fetched_tags
        USE_JSDELIVR=
        [ "$provider" != jsdelivr ] || USE_JSDELIVR=true
        return 0
    }
    _sing_box_perform_install() {
        printf 'download %s\n' "$1" >> "$events"
        _sing_box_build_url "$1" || return 1
        printf '%s\n' "$download_url" > "$case_dir/url"
        return "$download_rc"
    }

    printf '%s\n' "$choice_input" > "$case_dir/input"
    if download_sing_box < "$case_dir/input" > "$case_dir/result.log" 2>&1; then rc=0; else rc=$?; fi
    [ "$rc" -eq "$expected_rc" ] || { cat "$case_dir/result.log"; fail "expected rc=$expected_rc, got $rc"; }
    [ "$(grep -c '^fetch$' "$events" || :)" -eq "$expected_fetch" ] || fail 'unexpected fetch count'
    [ "$(grep -c '^download ' "$events" || :)" -eq "$expected_download" ] || fail 'unexpected download count'
    if [ "$expected_fetch" -eq 1 ]; then
        [ "$RELEASE_TAGS" = "$expected_tags" ] || fail 'filtered tags changed order, prefix or contents'
        if [ "$provider" = jsdelivr ]; then expected_jsdelivr=true; else expected_jsdelivr=; fi
        [ "$USE_JSDELIVR" = "$expected_jsdelivr" ] || fail 'provider flag changed'
    else
        [ "$RELEASE_TAGS" = unfetched ] && [ "$USE_JSDELIVR" = stale ] || fail 'release lookup state changed without fetching'
    fi
    if [ "$expected_download" -eq 1 ]; then
        assert_contains "$events" "download $expected_version"
        version=${expected_version#v}
        [ "$(cat "$case_dir/url")" = "$sing_box_tar_url/v$version/sing-box-$version-linux-arm64.tar.gz" ] || fail 'incorrect download URL or prefix'
    fi
    if [ "$expected_menu" -eq 1 ]; then
        assert_contains "$case_dir/result.log" "     1. ${tag_prefix}1.14.1"
        assert_contains "$case_dir/result.log" "     2. ${tag_prefix}1.13.3"
        assert_contains "$case_dir/result.log" 'Ручной ввод версии'
        for rejected in alpha beta rc.1 +build 1x14x2 1.14.1.1 nightly; do
            assert_absent "$case_dir/result.log" "$rejected"
        done
    else
        assert_absent "$case_dir/result.log" 'Ручной ввод версии'
        assert_absent "$case_dir/result.log" 'Введите порядковый номер'
    fi
    [ -z "$expected_error" ] || assert_contains "$case_dir/result.log" "$expected_error"
    if [ "$case_name" = interactive_skip ]; then
        [ "$bypass_sing_box" = true ] || fail 'skip flag not preserved'
    fi
    printf 'PASS %s\n' "$case_name"
)

for case_name in jsdelivr_mixed_first jsdelivr_mixed_second github_mixed \
    jsdelivr_prerelease_only github_prerelease_only empty_releases \
    latest_jsdelivr latest_github latest_prerelease_only validated \
    validated_download_failure latest_download_failure interactive_skip \
    interactive_manual unknown_policy mips32le mips32 unsupported; do
    run_case "$case_name"
done
printf 'All 18 downloader fixture tests passed.\n'
