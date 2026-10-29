#!/bin/sh
# Writes what this build was made from into the built app's Info.plist, so a
# copy of Lamp Bible names its own sources. Its version is always 0.1.0 build 1,
# so without this an installed app could only be identified by a note kept
# beside it.
#
#   LampMacCommit             this repository's commit
#   LampCoreCommit            ../lamp-bible-core's, which the app builds against
#                             by path rather than at a pinned version
#   LampBundledModulesSHA256  the bundled modules archive, built locally from
#                             ../lamp-bible-modules and not kept in git
#
# A commit ends in "-modified" when its checkout had uncommitted changes,
# untracked files included: core's package compiles whatever is in its
# Sources folder. Such a build cannot be made again from the commit alone.
#
# A checkout with no commit to read fails the build. Old builds are not kept,
# on the understanding that any build can be made again from what it names,
# so a build that names nothing is the one thing this must not produce.
#
# Run by the app target's last build phase, after the plist is processed and
# before the bundle is signed. Reads TARGET_BUILD_DIR, INFOPLIST_PATH and
# PROJECT_DIR as Xcode sets them.

set -eu

plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
sibling="${PROJECT_DIR}/.."

source_of() {
    if ! commit=$(git -C "$1" rev-parse HEAD 2>/dev/null); then
        echo "error: $1 is not a git checkout, so this build could not say what it was made from" >&2
        exit 1
    fi
    if [ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]; then
        commit="${commit}-modified"
    fi
    echo "$commit"
}

archive="${sibling}/lamp-bible-modules/modules_db/bundled_modules.db.zlib"
if [ -f "$archive" ]; then
    archive_sha=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
else
    archive_sha="missing"
fi

set_string() {
    /usr/libexec/PlistBuddy -c "Set :$1 $2" "$plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$plist"
}

mac=$(source_of "$PROJECT_DIR")
core=$(source_of "${sibling}/lamp-bible-core")

set_string LampMacCommit "$mac"
set_string LampCoreCommit "$core"
set_string LampBundledModulesSHA256 "$archive_sha"
