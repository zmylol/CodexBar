#!/bin/zsh

set -euo pipefail

codexbar_script_dir=${0:A:h}
codexbar_user_home=${HOME:?User home is unavailable}
codexbar_support_root=${CODEXBAR_SUPPORT_ROOT:-"$codexbar_user_home/Library/Application Support/CodexBar"}
codexbar_codex_root=${CODEX_HOME:-"$codexbar_user_home/.codex"}
codexbar_hooks_file=${CODEXBAR_HOOKS_FILE:-"$codexbar_codex_root/hooks.json"}
codexbar_hook_executable=${CODEXBAR_HOOK_EXECUTABLE:-"$codexbar_support_root/bin/codexbar-hook"}
codexbar_backup_root="$codexbar_support_root/HookConfigBackups"
codexbar_original_root="$codexbar_support_root/HookConfigOriginal"
codexbar_managed_executables_file="$codexbar_original_root/managed-executables"
codexbar_config_lock="$codexbar_support_root/.hook-config.lock"

codexbar_require_safe_directory() {
    local path_value=${1:a}
    if [[ -L "$path_value" ]]; then
        print -u2 "CodexBar will not use a symbolic-link managed directory: $path_value"
        return 64
    fi
    if [[ -e "$path_value" && ! -d "$path_value" ]]; then
        print -u2 "CodexBar managed directory path is not a directory: $path_value"
        return 64
    fi
}

codexbar_require_safe_file() {
    local path_value=${1:a}
    if [[ -L "$path_value" ]]; then
        print -u2 "CodexBar will not use a symbolic-link managed file: $path_value"
        return 64
    fi
    if [[ -e "$path_value" && ! -f "$path_value" ]]; then
        print -u2 "CodexBar managed file path is not a regular file: $path_value"
        return 64
    fi
}

codexbar_require_within_support_root() {
    local path_value=$1
    local resolved_root
    local resolved_path
    resolved_root=$(/bin/realpath "$codexbar_support_root")
    resolved_path=$(/bin/realpath "$path_value")
    if [[ "$resolved_path" != "$resolved_root" && "$resolved_path" != "$resolved_root/"* ]]; then
        print -u2 "CodexBar managed path resolves outside its support directory: $path_value"
        return 64
    fi
}

codexbar_validate_config_paths() {
    if (( EUID == 0 )); then
        print -u2 "Do not modify Codex Hooks as root."
        return 77
    fi
    for path_value in "$codexbar_hooks_file" "$codexbar_support_root" "$codexbar_hook_executable"; do
        if [[ "$path_value" != /* || "${path_value:a}" == "/" ]]; then
            print -u2 "CodexBar Hook paths must be absolute, non-root paths: $path_value"
            return 64
        fi
    done

    codexbar_hooks_file=${codexbar_hooks_file:a}
    codexbar_support_root=${codexbar_support_root:a}
    codexbar_hook_executable=${codexbar_hook_executable:a}
    codexbar_backup_root="$codexbar_support_root/HookConfigBackups"
    codexbar_original_root="$codexbar_support_root/HookConfigOriginal"
    codexbar_managed_executables_file="$codexbar_original_root/managed-executables"
    codexbar_config_lock="$codexbar_support_root/.hook-config.lock"

    codexbar_require_safe_directory "${codexbar_hooks_file:h}"
    codexbar_require_safe_directory "$codexbar_support_root"
    codexbar_require_safe_directory "${codexbar_hook_executable:h}"
    codexbar_require_safe_directory "$codexbar_backup_root"
    codexbar_require_safe_directory "$codexbar_original_root"
    codexbar_require_safe_directory "$codexbar_config_lock"
    codexbar_require_safe_file "$codexbar_hooks_file"
    codexbar_require_safe_file "$codexbar_hook_executable"
    codexbar_require_safe_file "$codexbar_managed_executables_file"
    codexbar_require_safe_file "$codexbar_original_root/hooks.json"
    codexbar_require_safe_file "$codexbar_original_root/original-state"
    codexbar_require_safe_file "$codexbar_original_root/captured"
    codexbar_require_safe_file "$codexbar_config_lock/pid"
}

codexbar_prepare_directories() {
    /bin/mkdir -p \
        "${codexbar_hooks_file:h}" \
        "$codexbar_support_root" \
        "$codexbar_backup_root" \
        "$codexbar_original_root"
    codexbar_require_within_support_root "$codexbar_backup_root"
    codexbar_require_within_support_root "$codexbar_original_root"
    /bin/chmod 700 "$codexbar_support_root" "$codexbar_backup_root" "$codexbar_original_root"
}

codexbar_acquire_config_lock() {
    local attempts=0
    until /bin/mkdir "$codexbar_config_lock" 2>/dev/null; do
        if [[ -f "$codexbar_config_lock/pid" ]]; then
            local owner_pid
            owner_pid=$(/bin/cat "$codexbar_config_lock/pid" 2>/dev/null || true)
            if [[ "$owner_pid" == <-> ]] && ! /bin/kill -0 "$owner_pid" 2>/dev/null; then
                /bin/rm -f -- "$codexbar_config_lock/pid"
                /bin/rmdir "$codexbar_config_lock" 2>/dev/null || true
                continue
            fi
        fi
        attempts=$((attempts + 1))
        if (( attempts >= 100 )); then
            print -u2 "Timed out waiting for the CodexBar Hook configuration lock."
            return 75
        fi
        /bin/sleep 0.05
    done
    /bin/chmod 700 "$codexbar_config_lock"
    print -r -- "$$" > "$codexbar_config_lock/pid"
    /bin/chmod 600 "$codexbar_config_lock/pid"
}

codexbar_release_config_lock() {
    if [[ -d "$codexbar_config_lock" ]]; then
        /bin/rm -f -- "$codexbar_config_lock/pid"
        /bin/rmdir "$codexbar_config_lock" 2>/dev/null || true
    fi
}

codexbar_config_fingerprint() {
    if [[ -f "$codexbar_hooks_file" ]]; then
        /usr/bin/shasum -a 256 "$codexbar_hooks_file" | /usr/bin/awk '{print $1}'
    elif [[ -e "$codexbar_hooks_file" ]]; then
        print -r -- "unsupported"
    else
        print -r -- "missing"
    fi
}

codexbar_assert_config_unchanged() {
    local expected=$1
    local actual
    actual=$(codexbar_config_fingerprint)
    if [[ "$actual" != "$expected" ]]; then
        print -u2 "hooks.json changed while CodexBar was preparing the update; no changes were written."
        return 75
    fi
}

codexbar_backup_current() {
    if [[ -f "$codexbar_hooks_file" ]]; then
        local backup_name
        backup_name="hooks-$('/bin/date' -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM.json"
        /bin/cp -p "$codexbar_hooks_file" "$codexbar_backup_root/$backup_name"
        /bin/chmod 600 "$codexbar_backup_root/$backup_name"
        codexbar_prune_hook_backups
    fi
}

codexbar_prune_hook_backups() {
    local -a backups
    local oldest
    local candidate
    while true; do
        backups=("$codexbar_backup_root"/hooks-*.json(N))
        if (( ${#backups} <= 10 )); then
            return
        fi
        oldest=${backups[1]}
        for candidate in "${backups[@]}"; do
            if [[ "$candidate:t" < "$oldest:t" ]]; then
                oldest=$candidate
            fi
        done
        /bin/rm -f -- "$oldest"
    done
}

codexbar_capture_original_once() {
    if [[ -e "$codexbar_original_root/captured" ]]; then
        return
    fi
    if [[ -f "$codexbar_hooks_file" ]]; then
        /bin/cp -p "$codexbar_hooks_file" "$codexbar_original_root/hooks.json"
        /bin/chmod 600 "$codexbar_original_root/hooks.json"
        print -r -- "existing" > "$codexbar_original_root/original-state"
    else
        print -r -- "missing" > "$codexbar_original_root/original-state"
    fi
    /usr/bin/touch "$codexbar_original_root/captured"
    /bin/chmod 600 "$codexbar_original_root/original-state" "$codexbar_original_root/captured"
}

codexbar_transform() {
    local operation=$1
    local mode=$2
    local -a previous_executables
    previous_executables=()
    if [[ -f "$codexbar_managed_executables_file" ]]; then
        previous_executables=("${(@f)$(<"$codexbar_managed_executables_file")}")
    fi
    /usr/bin/osascript -l JavaScript "$codexbar_script_dir/hooks-config.js" \
        "$operation" "$codexbar_hooks_file" "$codexbar_hook_executable" "$mode" \
        "${previous_executables[@]}"
}

codexbar_record_managed_executable() {
    if [[ -f "$codexbar_managed_executables_file" ]] \
        && /usr/bin/grep -Fqx -- "$codexbar_hook_executable" "$codexbar_managed_executables_file"; then
        return
    fi
    print -r -- "$codexbar_hook_executable" >> "$codexbar_managed_executables_file"
    /bin/chmod 600 "$codexbar_managed_executables_file"
}

codexbar_atomic_write() {
    local content=$1
    local temporary
    temporary=$(/usr/bin/mktemp "${codexbar_hooks_file:h}/.hooks.json.codexbar.XXXXXX")
    print -rn -- "$content" > "$temporary"
    /bin/chmod 600 "$temporary"
    /bin/mv -f "$temporary" "$codexbar_hooks_file"
}

codexbar_atomic_copy() {
    local source=$1
    local temporary
    temporary=$(/usr/bin/mktemp "${codexbar_hooks_file:h}/.hooks.json.codexbar.XXXXXX")
    /bin/cp "$source" "$temporary"
    /bin/chmod 600 "$temporary"
    /bin/mv -f "$temporary" "$codexbar_hooks_file"
}

codexbar_validate_hooks_file() {
    local source=$1
    /usr/bin/osascript -l JavaScript "$codexbar_script_dir/hooks-config.js" \
        validate "$source" >/dev/null
}

codexbar_warn_inline_hooks() {
    local config_file="${codexbar_hooks_file:h}/config.toml"
    if [[ -f "$config_file" ]] && /usr/bin/awk '
        /^[[:space:]]*\[+hooks(\]|[.])/ {
            line = $0
            sub(/^[[:space:]]*\[+/, "", line)
            if (line !~ /^hooks[.]state(\]|[.])/) {
                found = 1
            }
        }
        END { exit found ? 0 : 1 }
    ' "$config_file"; then
        print -u2 "Warning: config.toml also contains inline hooks; Codex merges both sources and may show a startup warning."
    fi
}
