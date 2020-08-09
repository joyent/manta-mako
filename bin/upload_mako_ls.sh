#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright 2020 Joyent, Inc.
#

export PATH=/opt/local/bin:$PATH

PID=$$
PID_FILE=/tmp/upload_mako_ls.pid
OUT_DIR=/manta/mako_rollup
START_TIME=`date -u +"%Y-%m-%dT%H:%M:%SZ"`

function fatal {
    local LNOW=`date`
    echo "$LNOW: $(basename $0): fatal error: $*" >&2
    exit 1
}

function log {
    local LNOW=`date`
    echo "$LNOW: $(basename $0): info: $*" >&2
}

# Check the last pid to see if a previous cron is still running...
LAST_PID=$(cat $PID_FILE 2>/dev/null)

if [[ -n "$LAST_PID" ]]; then
    ps -p $LAST_PID >/dev/null
    if [[ $? -eq 0 ]]; then
        echo "$0 process still running.  Exiting..."
        exit 1
    fi
fi

echo -n $PID >$PID_FILE

log "starting mako rollup"

mkdir -p "$OUT_DIR"

/opt/smartdc/mako/bin/mako_rollup > "$OUT_DIR/mako_rollup.tmp"
if [[ $? -ne 0 ]]; then
    fatal "Mako rollup failed!"
else
    mv "$OUT_DIR/mako_rollup.tmp" "$OUT_DIR/mako_rollup.out"
fi

log "Cleaning up..."
rm $PID_FILE

log "Done."

exit 0;
