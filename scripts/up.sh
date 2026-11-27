#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: sudo ./scripts/up.sh [OPTIONS]

Installs FileExplorer.app to /Applications, registers it with LaunchServices,
sets it as the default macOS folder viewer (NSFileViewer), restarts Finder,
and launches File Explorer.

Options:
  --rebuild    Force rebuilding build/FileExplorer.app before installing
  -h, --help   Show this help message and exit
EOF
}

REBUILD=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rebuild)
            REBUILD=true
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
    echo "Please run with sudo: sudo ./scripts/up.sh" >&2
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
TARGET_GROUP="$(id -gn "$TARGET_USER")"
TARGET_HOME="$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory | awk '{print $2}')"
if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
    echo "Error: Could not resolve home directory for user '$TARGET_USER'." >&2
    exit 1
fi

run_as_user() {
    /bin/launchctl asuser "$TARGET_UID" /usr/bin/sudo -u "$TARGET_USER" HOME="$TARGET_HOME" "$@"
}

BUNDLE_ID="com.hackedple.fileexplorer"
SRC_APP="$ROOT_DIR/build/FileExplorer.app"
DEST_APP="/Applications/FileExplorer.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
BACKUP_DIR="$TARGET_HOME/Library/Application Support/FileExplorer"
BACKUP_FILE="$BACKUP_DIR/finder-backup.env"

if [[ "$REBUILD" == true || ! -d "$SRC_APP" ]]; then
    echo "1. Building FileExplorer.app as $TARGET_USER..."
    /usr/bin/sudo -u "$TARGET_USER" HOME="$TARGET_HOME" "$ROOT_DIR/scripts/build-app.sh"
else
    echo "1. Using existing bundle: $SRC_APP"
fi

if [[ ! -d "$SRC_APP" ]]; then
    echo "Error: Built app bundle not found at $SRC_APP" >&2
    exit 1
fi

echo "2. Installing to $DEST_APP..."
rm -rf "$DEST_APP"
/usr/bin/ditto "$SRC_APP" "$DEST_APP"
/usr/bin/xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
chmod -R a+rX "$DEST_APP"

echo "3. Registering app with LaunchServices..."
run_as_user "$LSREGISTER" -f "$DEST_APP"

echo "4. Saving original Finder defaults (once) and enabling File Explorer..."
mkdir -p "$BACKUP_DIR"
chown "$TARGET_USER:$TARGET_GROUP" "$BACKUP_DIR"

if [[ ! -f "$BACKUP_FILE" ]]; then
    PREV_NS_FILE_VIEWER="$(run_as_user /usr/bin/defaults read -g NSFileViewer 2>/dev/null || echo "__UNSET__")"
    PREV_FINDER_QUIT_MENU="$(run_as_user /usr/bin/defaults read com.apple.finder QuitMenuItem 2>/dev/null || echo "__UNSET__")"
    cat > "$BACKUP_FILE" <<EOF
PREV_NS_FILE_VIEWER=${PREV_NS_FILE_VIEWER}
PREV_FINDER_QUIT_MENU=${PREV_FINDER_QUIT_MENU}
EOF
    chown "$TARGET_USER:$TARGET_GROUP" "$BACKUP_FILE"
    chmod 644 "$BACKUP_FILE"
fi

run_as_user /usr/bin/defaults write -g NSFileViewer -string "$BUNDLE_ID"
run_as_user /usr/bin/defaults write com.apple.finder QuitMenuItem -bool true

echo "5. Restarting Finder and launching File Explorer..."
run_as_user /usr/bin/killall Finder 2>/dev/null || true
sleep 0.5
run_as_user /usr/bin/open "$DEST_APP"

CURRENT_VIEWER="$(run_as_user /usr/bin/defaults read -g NSFileViewer 2>/dev/null || echo "<unset>")"
echo ""
echo "File Explorer is UP!"
echo "  Target user:   $TARGET_USER ($TARGET_UID)"
echo "  Installed app: $DEST_APP"
echo "  NSFileViewer:  $CURRENT_VIEWER"
echo "  Restore with:  sudo $ROOT_DIR/scripts/down.sh"
