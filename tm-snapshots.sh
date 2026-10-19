#!/usr/bin/env bash
# DEPRECATED name (v0.5): kept one release so older QML/IPC callers keep
# working during the snapshot->backup terminology cutover. Remove in v0.6.
exec "$(dirname "$0")/tm-backups.sh" "$@"
