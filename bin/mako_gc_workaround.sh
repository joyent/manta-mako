#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2019, Joyent, Inc.
#

#
# Note, this is a workaround script, currently only intended for manual use
# when it is not possible to obtain a directory listing in
# /poseidon/stor/manta_gc/mako/<storage_id>
#

###############################################################################
# This cleans manta objects by first sucking down all files under:
#  /manta_gc/mako/$MANTA_STORAGE_ID
# Which come in the following format:
#  mako + \t + mantaStorageId + \t + ownerId + \t + objectId
#
# Since manta objects are kept under /manta/ownerId/objectId, the ids are taken
# from the lines in the file and used to find and unlink the objects on the
# local filesystem.  When it is done it deletes the file in manta.
###############################################################################


export PATH=/opt/local/bin:$PATH

## Global vars
RECORD_PATH=/var/tmp/INPUTS
BP_FILE=/var/tmp/bytes_processed

# Immutables

[ -z $SSH_KEY ] && SSH_KEY=/root/.ssh/id_rsa
[ -z $MANTA_KEY_ID ] && MANTA_KEY_ID=$(ssh-keygen -l -f $SSH_KEY.pub | awk '{print $2}')
[ -z $MANTA_URL ] && MANTA_URL=$(cat /opt/smartdc/mako/etc/gc_config.json | json -ga manta_url)
[ -z $MANTA_USER ] && MANTA_USER=$(json -f /opt/smartdc/common/etc/config.json manta.user)
[ -z $MANTA_STORAGE_ID ] && MANTA_STORAGE_ID=$(cat /opt/smartdc/mako/etc/gc_config.json | json -ga manta_storage_id)

AUTHZ_HEADER="keyId=\"/$MANTA_USER/keys/$MANTA_KEY_ID\",algorithm=\"rsa-sha256\""
DIR_TYPE='application/json; type=directory'
HOSTNAME=`hostname` LOG_TYPE='application/x-bzip2'
MPATH=/manta_gc/mako/$MANTA_STORAGE_ID
PID=$$
SCRIPT=$(basename $0)
TMP_DIR=/tmp/mako_gc
PID_FILE=/tmp/mako_gc.pid

# Mutables

NOW=""
SIGNATURE=""

ERROR="true"
FILE_COUNT=0
OBJECT_COUNT=0
TOMB_CLEAN_COUNT=0



## Functions

#
# For logging purposes, we keep track of the current date stamp in a global
# $LNOW variable.  To avoid calling date(1) whenever we wish to log, we only
# update the date stamp if the $SECONDS variable (which, in bash(1) is the
# integer number of seconds since the script was invoked) does not match our
# cached value.  This means that it's possible for our date stamp to be
# slightly out of date with respect to the system clock, but by less than one
# second -- which we consider to be acceptable considering we only have
# second resolution.
#
function updatelnow {
    if [[ $SECONDS != $LASTLNOW ]]; then
        LNOW=`date "+%Y-%m-%dT%H:%M:%S.000Z"`
        LASTLNOW=$SECONDS
    fi
}

function fatal {
    updatelnow
    echo "$LNOW: $SCRIPT ($PID): fatal error: $*" >&2
    audit
    exit 1
}


function log {
    updatelnow
    echo "$LNOW: $SCRIPT ($PID): info: $*" >&2
}


# Since we use bunyan, this mimics a json structure.
function audit {
    updatelnow

    echo "{\
\"audit\":true,\
\"name\":\"mako_gc\",\
\"level\":30,\
\"error\":$ERROR,\
\"msg\":\"audit\",\
\"v\":0,\
\"time\":\"$LNOW\",\
\"pid\":$PID,\
\"cronExec\":1,\
\"hostname\":\"$HOSTNAME\",\
\"fileCount\":\"$FILE_COUNT\",\
\"objectCount\":\"$OBJECT_COUNT\",\
\"tombDirCleanupCount\":\"0\"\
}" >&2
}


function auditRow {
    updatelnow

    echo "{\
\"audit\":true,\
\"name\":\"mako_gc\",\
\"level\":30,\
\"msg\":\"audit\",\
\"v\":0,\
\"time\":\"$LNOW\",\
\"pid\":$PID,\
\"hostname\":\"$HOSTNAME\",\
\"alreadyDeleted\":\"$1\",\
\"objectId\":\"$2\",\
\"size\":\"$3\",\
\"processed\":1\
}" >&2
}


function sign() {
    NOW=$(date -u "+%a, %d %h %Y %H:%M:%S GMT")
    SIGNATURE=$(echo "date: $NOW" | tr -d '\n' | \
        openssl dgst -sha256 -sign $SSH_KEY | \
        openssl enc -e -a | tr -d '\n') \
        || fatal "unable to sign data"
}


function manta_get_no_fatal() {
    sign || fatal "unable to sign"
    curl -fsSk \
        -X GET \
        -H "Date: $NOW" \
        -H "Authorization: Signature $AUTHZ_HEADER,signature=\"$SIGNATURE\"" \
        -H "Connection: close" \
        $MANTA_URL/$MANTA_USER/stor$1 2>&1
}


function manta_get_to_file() {
    sign || fatal "unable to sign"
    curl -fsSk \
        -X GET \
        -H "Date: $NOW" \
        -H "Authorization: Signature $AUTHZ_HEADER,signature=\"$SIGNATURE\"" \
        -H "Connection: close" \
        $MANTA_URL/$MANTA_USER/stor$1 >$2

    #
    # While failing to obtain a file is not good, we should log the error
    # and allow the caller to decide how to proceed.
    #
    if [[ $? -ne 0 ]]; then
        log "unable to get $1"
        return 1
    fi

    return 0
}


function manta_delete() {
    sign || fatal "unable to sign"
    curl -fsSk \
        -X DELETE \
        -H "Date: $NOW" \
        -H "Authorization: Signature $AUTHZ_HEADER,signature=\"$SIGNATURE\"" \
        -H "Connection: close" \
        $MANTA_URL/$MANTA_USER/stor$1

    if [[ $? -ne 0 ]]; then
        log "unable to delete $1"
        return 1
    fi

    return 0
}

#
# To ensure that we are processing the latest files generated by the mako-feeder
# we need to rsync with the feeder for our region. This funciton determines
# which region we are in by looking at the MANTA_URL that is set and maps it to
# a pre-defined feeder IP. Once determined this function will ensure that rsync
# has been called and that /var/tmp/INPUTS is populated with the most recent
# data
#
function rsync_feeder() {
    declare -A FEEDER_MAP
    FEEDER_MAP["us-east"]="10.64.7.121"
    FEEDER_MAP["eu-central"]="10.72.4.77"
    FEEDER_MAP["ap-southeast"]="10.80.2.152"
    FEEDER_MAP["ap-northeast"]="10.92.68.54"

    mkdir -p $RECORD_PATH

    REGION=$(echo $MANTA_URL | awk -F'.' '{ print $2 }')
    FEEDER_IP=${FEEDER_MAP["$REGION"]}
    MSI=$(json -f /var/tmp/metadata.json MANTA_STORAGE_ID) && [[ -n $MSI ]] && rsync "rsync://$FEEDER_IP/root/var/tmp/makos/$MSI/*-*" $RECORD_PATH

    [[ $? -eq 0 ]] || fatal "Couldn't rsync from feeder"

    log "Successfully rsync'd with the feeder using MANTA_STORAGE_ID: $MSI"

    return 0
}

function log_bytes_processed () {
    touch $BP_FILE

    updatelnow

    #
    # In the event that we have no data in BP_FILE we assume this is the first
    # time that this has ever run and move forward with LBYTES equal to zero
    #
    local TOTAL_LOGICAL_BYTES="0"
    local TOTAL_PHYSICAL_BYTES="0"
    local LBYTES_LINE=""
    local LBYTES="0"
    local PBYTES_LINE=""
    local PBYTES="0"

    mapfile -t LAST_FOUR_LINES  < <(tail -n 4 $BP_FILE)
    if [[ ${#LAST_FOUR_LINES[@]} -eq 4 ]]; then
        LBYTES_LINE=${LAST_FOUR_LINES[1]}
        PBYTES_LINE=${LAST_FOUR_LINES[3]}
    fi

    local LB_ARRAY=($LBYTES_LINE)
    local LBYTES=${LB_ARRAY[7]}
    TOTAL_LOGICAL_BYTES=$[$LBYTES + $1]

    local PB_ARRAY=($PBYTES_LINE)
    local PBYTES=${PB_ARRAY[7]}
    TOTAL_PHYSICAL_BYTES=$[$PBYTES + $2]

    echo "$LNOW: $SCRIPT ($PID): current logical bytes processed: $1" >> $BP_FILE
    echo "$LNOW: $SCRIPT ($PID): total logical bytes deleted: $TOTAL_LOGICAL_BYTES" >> $BP_FILE
    echo "$LNOW: $SCRIPT ($PID): current physical bytes processed: $2" >> $BP_FILE
    echo "$LNOW: $SCRIPT ($PID): total physical bytes deleted: $TOTAL_PHYSICAL_BYTES" >> $BP_FILE

    return 0;
}

#
# Under certain circumstances, the directory of files containing instructions
# for object deletion may grow too large to be able to obtain a directory
# listing through traditional means.  As a result, we are unable to process
# any of those files because we don't know their names.  As a mitigation, we
# can obtain the file names manually by consulting the metadata tier directly
# in order to recreate what the results of what a successul directory listing
# would have looked like.  This function processes those files from a local
# source, specified by a path.  From there, we can proceed normally through the
# rest of the garbage collection process.
#
function process_file() {
    local RECORDS="$1"
    local ret=0

    while read -r line
    do
        FILE=$(basename "$line")
        MFILE=$MPATH/$FILE
        LFILE=$TMP_DIR/$FILE

        if [[ "/poseidon/stor$MFILE" != "$line" ]]
        then
            fatal "Mal-formed line: $line. Expected: /poseidon/stor/$MFILE"
        fi

        manta_get_to_file $MFILE $LFILE

        if [[ $? -ne 0 ]]; then
            continue
        fi

        log "Processing manta object $MFILE"

        while read -r LINE
        do
            #Filter out any lines that aren't meant for this storage node...
            if [[ ! $LINE =~ mako.*$MANTA_STORAGE_ID ]]
            then
                continue
            fi
            log "Processing $LINE"
            #Fields 3 and 4 are the owner and object ids, respectively.
            ARR=($LINE)
            OBJECT=/manta/${ARR[2]}/${ARR[3]}
            if [[ -f $OBJECT ]]
            then
                local SIZES=$(stat -c '%s %b %B' $OBJECT)
                local SIZES_ARRAY=($SIZES)
                local LOGICAL_BYTES="${SIZES_ARRAY[0]}"
                local NUM_BLKS="${SIZES_ARRAY[1]}"
                local BLK_SIZE="${SIZES_ARRAY[2]}"
                local PHYSICAL_BYTES=$[$BLK_SIZE * $NUM_BLKS]

                auditRow "false" "$OBJECT" "$LOGICAL_BYTES"
                rm $OBJECT
                [[ $? -eq 0 ]] || log "Couldn't rm $OBJECT"
                ((OBJECT_COUNT++))
                log_bytes_processed "$LOGICAL_BYTES" "$PHYSICAL_BYTES"
            else
                auditRow "true" "$OBJECT" "0"
            fi
        done < "$LFILE"

        rm $LFILE
        [[ $? -eq 0 ]] || fatal "Unable to rm $LFILE. Something is wrong."
        manta_delete $MFILE

        #
        # If removing the instruction file on the manta side either was not
        # successful, flag the failure so that this function returns 1.  This
        # will cause the script to preserve the local source so that we can
        # later determine whether or not it was actually removed.
        #
        if [[ $? -ne 0 ]]; then
            ret=1
            continue
        fi

        ((FILE_COUNT++))

        log "success processing $MFILE."
    done < "$RECORDS"
    return $ret
}

## Main

: ${MANTA_STORAGE_ID:?"Manta storage id must be set."}

mkdir -p $TMP_DIR

# Update our files to process
log "rsync with feeder"
rsync_feeder

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

if [[ -z "$RECORD_PATH" ]]
then
    fatal "No path specified."
fi

if [[ ! -d "$RECORD_PATH" ]]
then
    fatal "$RECORD_PATH does not exist."
fi

# Ok, we're good to start gc
log "starting gc"

for file in "$RECORD_PATH"/*
do
    process_file "$file"

    #
    # Only remove the file if it appears that we successfully processed the
    # entire thing, otherwise retain it for further analysis.
    #
    if [[ $? -eq 0 ]]; then
        rm "$file"
    fi
done

BP_FILE_SIZE=$(stat -c '%s' $BP_FILE)
BP_FILE_HALF_SIZE=$(($BP_FILE_SIZE / 2))

if [[ "$BP_FILE_SIZE" -ge 104857600 ]]; then
    split -b $BP_FILE_HALF_SIZE $BP_FILE "$BP_FILE."
    mv $BP_FILE "$BP_FILE.old"
    mv "$BP_FILE.ab" $BP_FILE
    rm "$BP_FILE.aa"
    rm "$BP_FILE.old"
fi

ERROR="false"
audit

# Clean up the last pid file...
rm $PID_FILE

exit 0;
