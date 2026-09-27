#!/usr/bin/env bash
#
# Folder-Locker: Core Engine (v1.0)
# Native double-click unlocking, unified password form, auto-lock on window close,
# and automatic cascade deletion of hidden vaults when the locked folder is deleted.
#
# Usage:
#   folderlock [lock|unlock|toggle|--watch|--monitor] <path>
#

set -o pipefail

APP_NAME="Folder-Locker"
VERSION="1.0"

# ---------------------------------------------------------------------------
# UI Notification and Dialog Helpers (Zenity)
# ---------------------------------------------------------------------------
show_error() {
    local message="$1"
    if command -v zenity >/dev/null 2>&1 && [ -n "${DISPLAY:-$WAYLAND_DISPLAY}" ]; then
        zenity --error --title="$APP_NAME" --text="$message" --width=380 2>/dev/null
    else
        echo "[$APP_NAME ERROR] $message" >&2
    fi
}

show_info() {
    local message="$1"
    if command -v zenity >/dev/null 2>&1 && [ -n "${DISPLAY:-$WAYLAND_DISPLAY}" ]; then
        zenity --info --title="$APP_NAME" --text="$message" --width=380 2>/dev/null
    else
        echo "[$APP_NAME INFO] $message"
    fi
}

check_dependencies() {
    local missing=()
    if ! command -v gocryptfs >/dev/null 2>&1; then
        missing+=("gocryptfs")
    fi
    if ! command -v zenity >/dev/null 2>&1; then
        missing+=("zenity")
    fi
    if ! command -v fusermount3 >/dev/null 2>&1 && ! command -v fusermount >/dev/null 2>&1; then
        missing+=("fuse3 or fuse")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        show_error "Missing required dependencies:\n\n${missing[*]}\n\nInstall them by running:\nsudo apt install gocryptfs zenity fuse3 wmctrl"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Mount and Path Resolution Utilities
# ---------------------------------------------------------------------------
unmount_fs() {
    local target="$1"
    sync
    if command -v fusermount3 >/dev/null 2>&1; then
        fusermount3 -u "$target" 2>&1 && return 0
    fi
    if command -v fusermount >/dev/null 2>&1; then
        fusermount -u "$target" 2>&1 && return 0
    fi
    return 1
}

is_gocryptfs_mount() {
    local dir="$1"
    local canonical
    canonical="$(realpath "$dir" 2>/dev/null)" || canonical="$dir"

    # Check via findmnt
    if command -v findmnt >/dev/null 2>&1; then
        local fstype
        fstype="$(findmnt -n -M "$canonical" -o FSTYPE 2>/dev/null || true)"
        if [[ "$fstype" == *"fuse.gocryptfs"* ]] || [[ "$fstype" == *"gocryptfs"* ]]; then
            return 0
        fi
    fi

    # Fallback via /proc/mounts
    if [ -f /proc/mounts ]; then
        if awk -v dir="$canonical" '$2 == dir && $3 ~ /gocryptfs/ {found=1} END {exit !found}' /proc/mounts 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# Normalize paths for vault (.vault), launcher (.desktop), and target directory
resolve_paths() {
    local input="$1"
    local canonical
    canonical="$(realpath -m "$input" 2>/dev/null)" || canonical="$input"

    local parent_dir
    parent_dir="$(dirname "$canonical")"
    local raw_base
    raw_base="$(basename "$canonical")"

    # Strip known extensions if present
    local base_name="$raw_base"
    if [[ "$base_name" == *.desktop ]]; then
        base_name="${base_name%.desktop}"
    fi
    if [[ "$base_name" =~ ^\.(.*)\.vault$ ]]; then
        base_name="${BASH_REMATCH[1]}"
    fi
    if [[ "$base_name" =~ ^\.(.*)\.desktop$ ]]; then
        base_name="${BASH_REMATCH[1]}"
    fi

    TARGET_DIR="${parent_dir}/${base_name}"
    VAULT_DIR="${parent_dir}/.${base_name}.vault"
    DESKTOP_FILE="${parent_dir}/${base_name}.desktop"
    HIDDEN_DESKTOP="${parent_dir}/.${base_name}.desktop"
    FOLDER_NAME="$base_name"

    # Self-healing: restore launcher if the system rebooted while the folder was open
    if [ ! -f "$DESKTOP_FILE" ] && [ -f "$HIDDEN_DESKTOP" ]; then
        if [ -d "$TARGET_DIR" ] && ! is_gocryptfs_mount "$TARGET_DIR"; then
            rmdir "$TARGET_DIR" 2>/dev/null || true
            mv "$HIDDEN_DESKTOP" "$DESKTOP_FILE" 2>/dev/null || true
        fi
    fi
}

open_folder_new_window() {
    local target="$1"
    local default_fm
    default_fm="$(xdg-mime query default inode/directory 2>/dev/null || true)"

    if [[ "$default_fm" == *"dolphin"* ]] || command -v dolphin >/dev/null 2>&1; then
        dolphin --new-window "$target" >/dev/null 2>&1 &
    elif [[ "$default_fm" == *"nemo"* ]] || command -v nemo >/dev/null 2>&1; then
        nemo --no-desktop --new-window "$target" >/dev/null 2>&1 &
    elif [[ "$default_fm" == *"nautilus"* ]] || command -v nautilus >/dev/null 2>&1; then
        nautilus --new-window "$target" >/dev/null 2>&1 &
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$target" >/dev/null 2>&1 &
    fi
}

# ---------------------------------------------------------------------------
# Cascade Deletion: Track vaults and delete hidden .vault when .desktop is removed
# ---------------------------------------------------------------------------
REGISTRY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/folderlock"
REGISTRY_FILE="${REGISTRY_DIR}/vaults.list"

register_vault() {
    local desktop_path="$1"
    local vault_path="$2"
    local target_path="$3"

    mkdir -p "$REGISTRY_DIR" 2>/dev/null || true
    echo "${desktop_path}|${vault_path}|${target_path}" >> "$REGISTRY_FILE"

    # Keep registry clean and sorted
    if [ -f "$REGISTRY_FILE" ]; then
        sort -u "$REGISTRY_FILE" -o "$REGISTRY_FILE" 2>/dev/null || true
    fi

    # Ensure monitor daemon is running
    ensure_monitor_running
}

cleanup_orphaned_vaults() {
    [ ! -f "$REGISTRY_FILE" ] && return 0

    local tmp_file
    tmp_file="$(mktemp 2>/dev/null || mktemp -t flock.XXXXXX)"

    while IFS='|' read -r desktop_file vault_dir target_dir; do
        [ -z "$desktop_file" ] && continue

        local parent_dir
        parent_dir="$(dirname "$desktop_file")"
        local base_name
        base_name="$(basename "$desktop_file" .desktop)"
        local hidden_desktop="${parent_dir}/.${base_name}.desktop"

        if [ -d "$vault_dir" ]; then
            # If folder is actively mounted, keep it
            if is_gocryptfs_mount "$target_dir"; then
                echo "${desktop_file}|${vault_dir}|${target_dir}" >> "$tmp_file"
                continue
            fi

            # If visible .desktop AND hidden .desktop are gone, the user deleted the locked folder!
            if [ ! -f "$desktop_file" ] && [ ! -f "$hidden_desktop" ]; then
                # Cascade delete the hidden vault directory
                rm -rf "$vault_dir" 2>/dev/null || true
                continue # Do not preserve in registry
            fi

            echo "${desktop_file}|${vault_dir}|${target_dir}" >> "$tmp_file"
        fi
    done < "$REGISTRY_FILE"

    mv "$tmp_file" "$REGISTRY_FILE" 2>/dev/null || true
}

run_monitor_daemon() {
    while true; do
        sleep 2
        cleanup_orphaned_vaults
    done
}

ensure_monitor_running() {
    if ! pgrep -f "folderlock.*--monitor" >/dev/null 2>&1; then
        nohup "$0" --monitor >/dev/null 2>&1 &
    fi
}

# ---------------------------------------------------------------------------
# Window Watcher: Strictly Lock When the Opened Window is Closed
# ---------------------------------------------------------------------------
watch_and_autolock() {
    local target_dir="$1"
    resolve_paths "$target_dir"

    # Wait for the file manager window to appear
    local win_id=""
    for ((i=0; i<20; i++)); do
        sleep 0.5
        if command -v wmctrl >/dev/null 2>&1; then
            win_id="$(wmctrl -l 2>/dev/null | grep -F "$FOLDER_NAME" | awk '{print $1}' | tail -n1 || true)"
            if [ -n "$win_id" ]; then
                break
            fi
        fi
    done

    # If the window was found, monitor until it is closed
    if [ -n "$win_id" ]; then
        while true; do
            sleep 1

            # If already unmounted externally, exit cleanly
            if ! is_gocryptfs_mount "$TARGET_DIR"; then
                exit 0
            fi

            # Check if this window still exists in the window manager
            if ! wmctrl -l 2>/dev/null | grep -q "^$win_id"; then
                # Window closed! Check if user opened another window of the same folder
                if wmctrl -l 2>/dev/null | grep -F "$FOLDER_NAME" >/dev/null 2>&1; then
                    win_id="$(wmctrl -l 2>/dev/null | grep -F "$FOLDER_NAME" | awk '{print $1}' | tail -n1)"
                    continue
                fi

                # Wait if any background process is still writing files (e.g. LibreOffice, text editor)
                while command -v fuser >/dev/null 2>&1 && fuser -m "$TARGET_DIR" >/dev/null 2>&1; do
                    sleep 2
                done

                # Unmount and restore locked desktop launcher (No notification as requested)
                sync
                if unmount_fs "$TARGET_DIR"; then
                    rmdir "$TARGET_DIR" 2>/dev/null || true
                    if [ -f "$HIDDEN_DESKTOP" ]; then
                        mv "$HIDDEN_DESKTOP" "$DESKTOP_FILE" 2>/dev/null || true
                    fi
                fi
                exit 0
            fi
        done
    fi
}

kill_existing_watcher() {
    local target_dir="$1"
    pkill -f "folderlock.*--watch.*$target_dir" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Core Operations: Lock and Double-Click Unlock
# ---------------------------------------------------------------------------
lock_folder() {
    local input="$1"
    resolve_paths "$input"

    cleanup_orphaned_vaults
    kill_existing_watcher "$TARGET_DIR"

    # If already mounted (open), unmount and lock
    if is_gocryptfs_mount "$TARGET_DIR"; then
        local unmount_err
        unmount_err="$(unmount_fs "$TARGET_DIR")"
        if [ $? -ne 0 ]; then
            show_error "Could not lock folder:\n$TARGET_DIR\n\nIt is currently in use by another application or terminal.\nPlease close open files and windows, then try again.\n\nDetails:\n$unmount_err"
            return 1
        fi

        rmdir "$TARGET_DIR" 2>/dev/null || true
        if [ -f "$HIDDEN_DESKTOP" ]; then
            mv "$HIDDEN_DESKTOP" "$DESKTOP_FILE" 2>/dev/null || true
        fi
        # No lock notification as requested
        return 0
    fi

    # If already locked (.desktop and .vault exist)
    if [ -f "$DESKTOP_FILE" ] && [ -d "$VAULT_DIR" ]; then
        show_info "Folder '$FOLDER_NAME' is already locked.\nDouble-click it anytime to open!"
        return 0
    fi

    if [ ! -d "$TARGET_DIR" ]; then
        show_error "The specified directory was not found:\n$TARGET_DIR"
        return 1
    fi

    if [ -e "$VAULT_DIR" ]; then
        show_error "A vault already exists at:\n$VAULT_DIR\n\nPlease move or remove it before locking."
        return 1
    fi

    # Single unified password dialog (New password + Confirm password)
    local credentials
    credentials="$(zenity --forms \
                          --title="$APP_NAME: Lock Folder" \
                          --text="Set protection password for folder '$FOLDER_NAME':" \
                          --add-password="New password:" \
                          --add-password="Confirm password:" \
                          --separator=$'\n' 2>/dev/null)"
    local status=$?
    if [ $status -ne 0 ]; then
        return 0 # User cancelled
    fi

    local pass1 pass2
    {
        IFS= read -r pass1
        IFS= read -r pass2
    } <<< "$credentials"

    if [ -z "$pass1" ]; then
        show_error "Password cannot be empty."
        return 1
    fi

    if [ "$pass1" != "$pass2" ]; then
        show_error "Passwords do not match!\nThe folder was NOT locked."
        return 1
    fi

    # Store password in secure temporary RAM file
    local secure_dir="${XDG_RUNTIME_DIR:-/dev/shm}"
    local passfile
    passfile="$(mktemp -p "$secure_dir" .flock.XXXXXX 2>/dev/null || mktemp /tmp/.flock.XXXXXX)"
    chmod 600 "$passfile"
    printf '%s' "$pass1" > "$passfile"
    unset pass1 pass2

    trap 'rm -f "$passfile" 2>/dev/null || true' RETURN EXIT

    # Create hidden vault directory
    if ! mkdir -p "$VAULT_DIR"; then
        show_error "Failed to create vault directory:\n$VAULT_DIR"
        rm -f "$passfile"
        return 1
    fi

    # Initialize gocryptfs inside the hidden vault
    local init_out
    init_out="$(gocryptfs -init -passfile "$passfile" -q "$VAULT_DIR" 2>&1)"
    if [ $? -ne 0 ]; then
        rm -f "$passfile"
        rmdir "$VAULT_DIR" 2>/dev/null || true
        show_error "Failed to initialize gocryptfs:\n$init_out"
        return 1
    fi

    # Mount temporarily in RAM to migrate files safely
    local temp_mount
    temp_mount="$(mktemp -d -p "$secure_dir" .flock_mount.XXXXXX 2>/dev/null || mktemp -d /tmp/.flock_mount.XXXXXX)"
    local mount_out
    mount_out="$(gocryptfs -passfile "$passfile" -q "$VAULT_DIR" "$temp_mount" 2>&1)"
    local mount_status=$?
    rm -f "$passfile"

    if [ $mount_status -ne 0 ]; then
        rmdir "$temp_mount" 2>/dev/null || true
        rm -rf "$VAULT_DIR" 2>/dev/null || true
        show_error "Failed to prepare temporary mount:\n$mount_out"
        return 1
    fi

    # Move all contents (including hidden dotfiles) into the vault
    shopt -s dotglob nullglob
    local items=("$TARGET_DIR"/*)
    if [ ${#items[@]} -gt 0 ]; then
        if ! mv -- "${items[@]}" "$temp_mount/" 2>&1; then
            show_error "Warning: An error occurred while transferring files to the vault."
        fi
    fi
    shopt -u dotglob nullglob

    sync
    unmount_fs "$temp_mount" >/dev/null 2>&1
    rmdir "$temp_mount" 2>/dev/null || true

    # Remove the empty original directory
    rmdir "$TARGET_DIR" 2>/dev/null || true

    # Create native double-click desktop launcher with locked folder icon
    cat <<EOF > "$DESKTOP_FILE"
[Desktop Entry]
Type=Application
Name=$FOLDER_NAME
Comment=Locked Folder (Folder-Locker)
Exec=/usr/bin/folderlock unlock "%k"
Icon=folder-locked
Terminal=false
Categories=Utility;
EOF
    chmod +x "$DESKTOP_FILE" 2>/dev/null || true

    # Grant trust metadata for GNOME/Nautilus if available
    if command -v gio >/dev/null 2>&1; then
        gio set "$DESKTOP_FILE" "metadata::trusted" "yes" 2>/dev/null || true
    fi

    # Register vault for automatic cascade deletion
    register_vault "$DESKTOP_FILE" "$VAULT_DIR" "$TARGET_DIR"

    # Notification removed as requested by user
    return 0
}

unlock_folder() {
    local input="$1"
    resolve_paths "$input"

    # If already mounted, bring window to front
    if is_gocryptfs_mount "$TARGET_DIR"; then
        open_folder_new_window "$TARGET_DIR"
        nohup "$0" --watch "$TARGET_DIR" >/dev/null 2>&1 &
        return 0
    fi

    # Verify hidden vault exists
    if [ ! -d "$VAULT_DIR" ]; then
        show_error "Vault directory not found:\n$VAULT_DIR"
        return 1
    fi

    # Prompt for password
    local pass
    pass="$(zenity --password --title="$APP_NAME: Open Locked Folder" \
                   --text="Enter password to open '$FOLDER_NAME':" 2>/dev/null)"
    local status=$?
    if [ $status -ne 0 ]; then
        return 0 # User cancelled
    fi

    if [ -z "$pass" ]; then
        show_error "Password cannot be empty."
        return 1
    fi

    # Store password in RAM
    local secure_dir="${XDG_RUNTIME_DIR:-/dev/shm}"
    local passfile
    passfile="$(mktemp -p "$secure_dir" .flock.XXXXXX 2>/dev/null || mktemp /tmp/.flock.XXXXXX)"
    chmod 600 "$passfile"
    printf '%s' "$pass" > "$passfile"
    unset pass

    trap 'rm -f "$passfile" 2>/dev/null || true' RETURN EXIT

    mkdir -p "$TARGET_DIR"

    # Hide desktop launcher while folder is open (no duplicate items)
    if [ -f "$DESKTOP_FILE" ]; then
        mv "$DESKTOP_FILE" "$HIDDEN_DESKTOP" 2>/dev/null || true
    fi

    # Mount gocryptfs directly onto TARGET_DIR
    local mount_out
    mount_out="$(gocryptfs -passfile "$passfile" -q "$VAULT_DIR" "$TARGET_DIR" 2>&1)"
    local mount_status=$?
    rm -f "$passfile"

    if [ $mount_status -ne 0 ]; then
        rmdir "$TARGET_DIR" 2>/dev/null || true
        if [ -f "$HIDDEN_DESKTOP" ]; then
            mv "$HIDDEN_DESKTOP" "$DESKTOP_FILE" 2>/dev/null || true
        fi

        if echo "$mount_out" | grep -qiE "password incorrect|wrong password|mac check failed"; then
            show_error "Incorrect password!\nFolder '$FOLDER_NAME' could not be opened."
        else
            show_error "Error opening folder:\n$mount_out"
        fi
        return 1
    fi

    # Open in a NEW file manager window
    open_folder_new_window "$TARGET_DIR"

    # Launch background watcher to strictly lock when this window is closed
    nohup "$0" --watch "$TARGET_DIR" >/dev/null 2>&1 &

    return 0
}

toggle_folder() {
    local input="$1"
    resolve_paths "$input"

    if is_gocryptfs_mount "$TARGET_DIR"; then
        lock_folder "$TARGET_DIR"
    elif [ -f "$DESKTOP_FILE" ] || [ -d "$VAULT_DIR" ]; then
        unlock_folder "$input"
    else
        lock_folder "$input"
    fi
}

show_help() {
    cat <<EOF
$APP_NAME v$VERSION - Folder encryption with native double-click and auto-lock.

Usage:
  folderlock lock <folder>      Lock folder with password and create double-click launcher.
  folderlock unlock <folder>    Prompt password, mount, and open in new window.
  folderlock toggle <folder>    Toggle between locked and unlocked.
  folderlock --monitor          Run background cascade deletion monitor daemon.
  folderlock --version          Display version.
  folderlock --help             Display this help.
EOF
}

# ---------------------------------------------------------------------------
# Main Execution Entry Point
# ---------------------------------------------------------------------------
check_dependencies

ACTION="$1"
shift || true

case "$ACTION" in
    --watch)
        if [ -n "$1" ]; then
            watch_and_autolock "$1"
        fi
        exit 0
        ;;
    --monitor)
        run_monitor_daemon
        exit 0
        ;;
    lock|--lock)
        if [ -z "$1" ]; then
            show_error "No folder specified to lock."
            exit 1
        fi
        for item in "$@"; do
            lock_folder "$item"
        done
        ;;
    unlock|--unlock)
        if [ -z "$1" ]; then
            show_error "No item specified to open."
            exit 1
        fi
        for item in "$@"; do
            unlock_folder "$item"
        done
        ;;
    toggle|--toggle)
        if [ -z "$1" ]; then
            show_error "No item specified."
            exit 1
        fi
        for item in "$@"; do
            toggle_folder "$item"
        done
        ;;
    -v|--version)
        echo "$APP_NAME version $VERSION"
        exit 0
        ;;
    -h|--help)
        show_help
        exit 0
        ;;
    *)
        if [ -n "$ACTION" ] && [ -e "$ACTION" ]; then
            if [[ "$ACTION" == *.desktop ]] || is_gocryptfs_mount "$ACTION"; then
                toggle_folder "$ACTION"
            elif [ -d "$ACTION" ]; then
                lock_folder "$ACTION"
            else
                toggle_folder "$ACTION"
            fi
        else
            show_help
            exit 1
        fi
        ;;
esac
