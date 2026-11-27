#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: sudo ./scripts/down.sh [OPTIONS]

Quits FileExplorer, restores macOS Finder as the default folder viewer
(NSFileViewer), unregisters/removes /Applications/FileExplorer.app, and
relaunches Finder.

Options:
  --keep-app   Restore Finder as default without removing /Applications/FileExplorer.app
  -h, --help   Show this help message and exit
EOF
}

KEEP_APP=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-app)
            KEEP_APP=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Please run with sudo: sudo ./scripts/down.sh" >&2
    exit 1
fi

SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
ROOT_DIR="$(cd -P "$(dirname "$SOURCE")/.." && pwd)"

TARGET_USER="${SUDO_USER:-$(stat -f '%Su' /dev/console 2>/dev/null || true)}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    echo "Error: Could not determine a non-root desktop user (SUDO_USER/console)." >&2
    exit 1
fi

TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_HOME="$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory | awk '{print $2}')"
if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
    echo "Error: Could not resolve home directory for user '$TARGET_USER'." >&2
    exit 1
fi

run_as_user() {
    /bin/launchctl asuser "$TARGET_UID" /usr/bin/sudo -u "$TARGET_USER" HOME="$TARGET_HOME" "$@"
}

BUNDLE_ID="com.hackedple.fileexplorer"
DEST_APP="/Applications/FileExplorer.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
BACKUP_FILE="$TARGET_HOME/Library/Application Support/FileExplorer/finder-backup.env"

echo "1. Quitting File Explorer..."
run_as_user /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
sleep 0.4
/usr/bin/pkill -u "$TARGET_UID" -x FileExplorerApp 2>/dev/null || true

echo "2. Restoring original macOS Finder defaults..."
PREV_NS_FILE_VIEWER="__UNSET__"
PREV_FINDER_QUIT_MENU="__UNSET__"

if [[ -f "$BACKUP_FILE" ]]; then
    while IFS='=' read -r key val || [[ -n "$key" ]]; do
        case "$key" in
            PREV_NS_FILE_VIEWER)
                PREV_NS_FILE_VIEWER="$val"
                ;;
            PREV_FINDER_QUIT_MENU)
                PREV_FINDER_QUIT_MENU="$val"
                ;;
        esac
    done < "$BACKUP_FILE"
fi

if [[ -n "$PREV_NS_FILE_VIEWER" && "$PREV_NS_FILE_VIEWER" != "__UNSET__" && "$PREV_NS_FILE_VIEWER" != "$BUNDLE_ID" ]]; then
    run_as_user /usr/bin/defaults write -g NSFileViewer -string "$PREV_NS_FILE_VIEWER"
else
    run_as_user /usr/bin/defaults delete -g NSFileViewer 2>/dev/null || true
fi

case "$PREV_FINDER_QUIT_MENU" in
    1|true|TRUE|YES|yes)
        run_as_user /usr/bin/defaults write com.apple.finder QuitMenuItem -bool true
        ;;
    0|false|FALSE|NO|no)
        run_as_user /usr/bin/defaults write com.apple.finder QuitMenuItem -bool false
        ;;
    *)
        run_as_user /usr/bin/defaults delete com.apple.finder QuitMenuItem 2>/dev/null || true
        ;;
esac

rm -f "$BACKUP_FILE"

if [[ "$KEEP_APP" == false ]]; then
    echo "3. Unregistering and removing $DEST_APP..."
    if [[ -d "$DEST_APP" ]]; then
        run_as_user "$LSREGISTER" -u "$DEST_APP" 2>/dev/null || true
        rm -rf "$DEST_APP"
    fi
else
    echo "3. Keeping $DEST_APP (--keep-app)."
fi

echo "4. Relaunching macOS Finder..."
run_as_user /usr/bin/killall Finder 2>/dev/null || true
sleep 0.5
run_as_user /usr/bin/open -a Finder

CURRENT_VIEWER="$(run_as_user /usr/bin/defaults read -g NSFileViewer 2>/dev/null || echo "<unset — macOS Finder default>")"
echo ""
echo "macOS Finder is restored!"
echo "  Target user:  $TARGET_USER ($TARGET_UID)"
echo "  NSFileViewer: $CURRENT_VIEWER"
echo "  Re-enable:    sudo $ROOT_DIR/scripts/up.sh"
