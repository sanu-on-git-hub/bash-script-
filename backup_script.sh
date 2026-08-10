#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

###############################################################################
# PROXMOX BACKUP TASK MONITOR
#
# Existing functionality retained:
#   - Detect running backup tasks
#   - Calculate task runtime from UPID
#   - Stop tasks exceeding threshold
#   - Send email alert
#   - Maintain monitor log
#
# Added functionality:
#   - ONE CSV report containing EVERY currently running backup task
#   - Running tasks are included regardless of runtime
#   - Running check count for every task
#   - First time task was observed
#   - Last time task was observed
#   - Complete PBS task-log information
#   - Latest task-log message
#   - Long-running flag (> 5 hours)
#   - Reason/activity information
#   - Backup target / folder / VM information
#   - Raw PBS task-list information
#   - Raw PBS task-log information
#
###############################################################################

###############################################################################
# BASIC CONFIGURATION
###############################################################################

LOCKFILE="/tmp/pbs_backup_monitor.lock"

LOGFILE="/var/log/pbs_backup_monitor.log"

STATE_DIR="/var/lib/pbs-backup-monitor"

ALERT_DIR="$STATE_DIR/alerted"

# State used to remember how many times each task has been observed running.
RUNNING_STATE_DIR="$STATE_DIR/running-state"

# ONE current CSV report.
REPORT_DIR="$STATE_DIR/reports"
CSV_FILE="$REPORT_DIR/pbs_running_tasks.csv"

###############################################################################
# LONG-RUNNING THRESHOLD
#
# IMPORTANT:
#
# CSV:
#   ALL running tasks are included.
#
# Long-running:
#   Runtime > 5 hours.
#
# Existing stop/email logic:
#   Only applies when runtime is > 5 hours.
###############################################################################

THRESHOLD_MINUTES=300
THRESHOLD_SECONDS=$((THRESHOLD_MINUTES * 60))

###############################################################################
# STOP CONFIGURATION
###############################################################################

MAX_STOP_ATTEMPTS=12
STOP_WAIT=15

###############################################################################
# EMAIL
###############################################################################

RECIPIENTS=("systemadmin@1point1.com")

HOSTNAME_SHORT="$(hostname 2>/dev/null || echo unknown)"

HOSTNAME_FQDN="$(
    hostname -f 2>/dev/null ||
    hostname 2>/dev/null ||
    echo unknown
)"

IPADDR="$(
    hostname -I 2>/dev/null |
    awk '{print $1}' ||
    true
)"

[ -z "${IPADDR:-}" ] && IPADDR="unknown"

MAIL_FROM="root@ogsrvcmpbs.1point1.in"

###############################################################################
# CREATE DIRECTORIES
###############################################################################

mkdir -p "$(dirname "$LOGFILE")"
mkdir -p "$ALERT_DIR"
mkdir -p "$RUNNING_STATE_DIR"
mkdir -p "$REPORT_DIR"

touch "$LOGFILE"

###############################################################################
# LOCK
###############################################################################

exec 200>"$LOCKFILE"

flock -n 200 || exit 0

###############################################################################
# LOG FUNCTION
###############################################################################

log() {

    printf '%s - %s\n' \
        "$(date '+%F %T')" \
        "$*" >> "$LOGFILE"
}

###############################################################################
# CSV ESCAPE FUNCTION
#
# Proper CSV quoting.
# Handles:
#   commas
#   quotes
#   newlines
###############################################################################

csv_escape() {

    local value="${1:-}"

    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    value="${value//\"/\"\"}"

    printf '"%s"' "$value"
}

###############################################################################
# SEND ALERT
###############################################################################

send_alert() {

    local subject="$1"
    local bodyfile="$2"
    local recipient

    ###########################################################################
    # mail
    ###########################################################################

    if command -v mail >/dev/null 2>&1; then

        for recipient in "${RECIPIENTS[@]}"; do

            mail -s "$subject" "$recipient" < "$bodyfile" ||
                log "mail failed for $recipient"

        done

        return 0
    fi

    ###########################################################################
    # mailx
    ###########################################################################

    if command -v mailx >/dev/null 2>&1; then

        for recipient in "${RECIPIENTS[@]}"; do

            mailx -s "$subject" "$recipient" < "$bodyfile" ||
                log "mailx failed for $recipient"

        done

        return 0
    fi

    ###########################################################################
    # sendmail
    ###########################################################################

    if command -v sendmail >/dev/null 2>&1; then

        for recipient in "${RECIPIENTS[@]}"; do

            local tmpmsg

            tmpmsg="$(mktemp)"

            {
                printf 'To: %s\n' "$recipient"
                printf 'From: %s\n' "$MAIL_FROM"
                printf 'Subject: %s\n' "$subject"
                printf '\n'
                cat "$bodyfile"
            } > "$tmpmsg"

            sendmail -t < "$tmpmsg" ||
                log "sendmail failed for $recipient"

            rm -f "$tmpmsg"

        done

        return 0
    fi

    log "No mail utility found (mail/mailx/sendmail missing)"

    return 1
}

###############################################################################
# HASH UPID
###############################################################################

hash_upid() {

    printf '%s' "$1" |
        sha256sum |
        awk '{print $1}'
}

###############################################################################
# FORMAT RUNTIME
###############################################################################

format_runtime() {

    local runtime="$1"

    local days
    local hours
    local minutes
    local seconds

    days=$((runtime / 86400))

    hours=$(((runtime % 86400) / 3600))

    minutes=$(((runtime % 3600) / 60))

    seconds=$((runtime % 60))

    if [ "$days" -gt 0 ]; then

        printf '%dd %02dh %02dm %02ds' \
            "$days" \
            "$hours" \
            "$minutes" \
            "$seconds"

    else

        printf '%02dh %02dm %02ds' \
            "$hours" \
            "$minutes" \
            "$seconds"

    fi
}

###############################################################################
# GET BACKUP TARGET
###############################################################################

get_backup_target() {

    local upid="$1"

    local target_raw

    target_raw="$(
        printf '%s' "$upid" |
        awk -F: '{print $8}'
    )"

    printf '%s' "$target_raw" |
        sed 's/\\x3a/:/g'
}

###############################################################################
# GET VM ID
###############################################################################

get_vm_id() {

    local target="$1"

    local vmid

    vmid="$(
        printf '%s' "$target" |
        sed -n 's/.*vm-\([0-9][0-9]*\).*/vm-\1/p'
    )"

    if [ -z "$vmid" ]; then
        vmid="$target"
    fi

    printf '%s' "$vmid"
}

###############################################################################
# GET DATASTORE
###############################################################################

get_datastore() {

    local target="$1"

    if [[ "$target" == *:* ]]; then

        printf '%s' "${target%%:*}"

    else

        printf '%s' "unknown"

    fi
}

###############################################################################
# GET FOLDER / TARGET NAME
###############################################################################

get_folder_name() {

    local target="$1"

    if [ -z "$target" ]; then

        printf '%s' "unknown"

    else

        printf '%s' "$target"

    fi
}

###############################################################################
# GET PBS TASK LOG
###############################################################################

get_task_log() {

    local upid="$1"

    proxmox-backup-manager task log "$upid" 2>/dev/null ||
        true
}

###############################################################################
# GET LAST TASK LOG LINE
###############################################################################

get_last_task_log_line() {

    local task_log="$1"

    if [ -z "$task_log" ]; then

        printf '%s' "No PBS task log available"

        return
    fi

    printf '%s\n' "$task_log" |
        sed '/^[[:space:]]*$/d' |
        tail -n 1
}

###############################################################################
# GET LAST TASK LOG TIME
###############################################################################

get_last_task_log_time() {

    local task_log="$1"

    local last_line

    if [ -z "$task_log" ]; then

        printf '%s' "unknown"

        return
    fi

    last_line="$(
        printf '%s\n' "$task_log" |
        sed '/^[[:space:]]*$/d' |
        tail -n 1
    )"

    if [[ "$last_line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then

        printf '%s' "${BASH_REMATCH[1]}"

    else

        printf '%s' "unknown"

    fi
}

###############################################################################
# DETERMINE WHY TASK IS STILL RUNNING
###############################################################################

determine_reason() {

    local message="$1"

    if [ -z "$message" ]; then

        printf '%s' "No recent task activity found"

        return
    fi

    if [ "$message" = "No PBS task log available" ]; then

        printf '%s' "No PBS task log available"

        return
    fi

    local lower

    lower="$(
        printf '%s' "$message" |
        tr '[:upper:]' '[:lower:]'
    )"

    case "$lower" in

        *upload*|*uploading*)

            printf '%s' \
                "Backup data appears to still be uploading"
            ;;

        *download*|*downloading*)

            printf '%s' \
                "Data appears to still be downloading"
            ;;

        *chunk*)

            printf '%s' \
                "Backup chunks are still being processed"
            ;;

        *snapshot*)

            printf '%s' \
                "Snapshot processing is still active"
            ;;

        *verify*|*verification*)

            printf '%s' \
                "Backup verification is still active"
            ;;

        *index*)

            printf '%s' \
                "Backup index is still being processed"
            ;;

        *catalog*)

            printf '%s' \
                "Backup catalog is still being processed"
            ;;

        *wait*|*waiting*)

            printf '%s' \
                "Task appears to be waiting"
            ;;

        *lock*)

            printf '%s' \
                "Task may be waiting for a lock"
            ;;

        *connection*|*connecting*)

            printf '%s' \
                "Task appears to be processing a connection"
            ;;

        *error*|*failed*)

            printf '%s' \
                "Latest task activity contains an error/failure indication"
            ;;

        *)

            printf '%s' \
                "Task is still running; latest activity requires investigation"
            ;;

    esac
}

###############################################################################
# RUNNING CHECK COUNT
#
# Every UPID gets a persistent state file.
#
# Example:
#
# First script run:
#   count = 1
#
# Second run:
#   count = 2
#
# Third run:
#   count = 3
#
# If cron runs every 5 minutes:
#
#   5 minutes  = 1
#   10 minutes = 2
#   15 minutes = 3
#   ...
#   5 hours    = approximately 60
#
###############################################################################

get_running_count() {

    local upid="$1"
    local hash="$2"

    local state_file="$RUNNING_STATE_DIR/$hash"

    local count
    local first_seen

    count=0
    first_seen=""

    if [ -f "$state_file" ]; then

        count="$(
            awk -F'\t' '
                $1 == "COUNT" {
                    print $2
                }
            ' "$state_file" 2>/dev/null |
            head -n 1 ||
            true
        )"

        first_seen="$(
            awk -F'\t' '
                $1 == "FIRST_SEEN" {
                    print $2
                }
            ' "$state_file" 2>/dev/null |
            head -n 1 ||
            true
        )"

    fi

    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        count=0
    fi

    count=$((count + 1))

    if [ -z "$first_seen" ]; then

        first_seen="$(date '+%F %T')"

    fi

    {
        printf 'COUNT\t%s\n' "$count"
        printf 'FIRST_SEEN\t%s\n' "$first_seen"
        printf 'LAST_SEEN\t%s\n' "$(date '+%F %T')"
        printf 'UPID\t%s\n' "$upid"
    } > "$state_file"

    RUNNING_CHECK_COUNT="$count"
    RUNNING_FIRST_SEEN="$first_seen"
    RUNNING_LAST_SEEN="$(date '+%F %T')"
}

###############################################################################
# REMOVE OLD RUNNING STATE
#
# A task that disappears from the current running list is no longer running.
#
# Its state is removed so that a future NEW task does not inherit an old
# monitoring count.
###############################################################################

cleanup_old_running_state() {

    local state_file
    local stored_upid

    for state_file in "$RUNNING_STATE_DIR"/*; do

        [ -f "$state_file" ] || continue

        stored_upid="$(
            awk -F'\t' '
                $1 == "UPID" {
                    print substr($0, index($0,$2))
                }
            ' "$state_file" 2>/dev/null |
            head -n 1 ||
            true
        )"

        if [ -z "$stored_upid" ]; then
            rm -f "$state_file"
            continue
        fi

        if ! printf '%s\n' "$CURRENT_RUNNING_UPIDS" |
            grep -Fqx "$stored_upid"; then

            rm -f "$state_file"

            log "Removed completed task running-state: $stored_upid"
        fi

    done
}

###############################################################################
# START
###############################################################################

log "==============================================================="
log "PBS backup monitor started"
log "Hostname          : $HOSTNAME_FQDN"
log "IP Address        : $IPADDR"
log "Threshold         : MORE THAN $THRESHOLD_MINUTES minutes"
log "CSV               : $CSV_FILE"
log "==============================================================="

###############################################################################
# GET ALL RUNNING BACKUP TASKS
#
# IMPORTANT:
#
# This is the SAME source used by the original script.
#
# ALL running backup tasks are processed.
###############################################################################

RUNNING_TASKS="$(
    proxmox-backup-manager task list 2>/dev/null |
    grep 'backup:' |
    grep 'running' ||
    true
)"

###############################################################################
# TOTAL RUNNING TASK COUNT
###############################################################################

if [ -n "$RUNNING_TASKS" ]; then

    TOTAL_RUNNING_TASKS="$(
        printf '%s\n' "$RUNNING_TASKS" |
        wc -l |
        xargs
    )"

else

    TOTAL_RUNNING_TASKS=0

fi

log "Total currently running backup tasks: $TOTAL_RUNNING_TASKS"

###############################################################################
# SAVE CURRENT UPIDS
###############################################################################

CURRENT_RUNNING_UPIDS=""

while IFS= read -r line; do

    [ -z "$line" ] && continue

    current_upid="$(
        printf '%s\n' "$line" |
        grep -o 'UPID:[^ ]*' ||
        true
    )"

    [ -z "$current_upid" ] && continue

    CURRENT_RUNNING_UPIDS+="$current_upid"$'\n'

done <<< "$RUNNING_TASKS"

###############################################################################
# REMOVE STATE FOR TASKS NO LONGER RUNNING
###############################################################################

cleanup_old_running_state

###############################################################################
# CREATE CSV HEADER
#
# CSV IS RECREATED EVERY RUN.
#
# Therefore it is always a current snapshot of ALL running tasks.
###############################################################################

REPORT_TIME="$(date '+%F %T')"

{

    csv_escape "Report_Time"
    printf ','

    csv_escape "Server_Hostname"
    printf ','

    csv_escape "Server_FQDN"
    printf ','

    csv_escape "Server_IP"
    printf ','

    csv_escape "Total_Running_Tasks"
    printf ','

    csv_escape "Task_Status"
    printf ','

    csv_escape "Status_Color"
    printf ','

    csv_escape "UPID"
    printf ','

    csv_escape "Task_Hash"
    printf ','

    csv_escape "VM_CT_ID"
    printf ','

    csv_escape "Backup_Target"
    printf ','

    csv_escape "Folder_Name"
    printf ','

    csv_escape "Datastore"
    printf ','

    csv_escape "Task_Start_Time"
    printf ','

    csv_escape "Current_Time"
    printf ','

    csv_escape "Running_Duration"
    printf ','

    csv_escape "Runtime_Seconds"
    printf ','

    csv_escape "Runtime_Minutes"
    printf ','

    csv_escape "Running_Check_Count"
    printf ','

    csv_escape "First_Observed_Running"
    printf ','

    csv_escape "Last_Observed_Running"
    printf ','

    csv_escape "Long_Running"
    printf ','

    csv_escape "Long_Running_Threshold"
    printf ','

    csv_escape "Long_Running_Status"
    printf ','

    csv_escape "Last_Log_Time"
    printf ','

    csv_escape "Last_Log_Message"
    printf ','

    csv_escape "Why_Still_Running"
    printf ','

    csv_escape "Complete_Task_Log"
    printf ','

    csv_escape "Raw_Task_List_Line"

    printf '\n'

} > "$CSV_FILE"

###############################################################################
# PROCESS EVERY RUNNING TASK
###############################################################################

while IFS= read -r line; do

    [ -z "$line" ] && continue

    ###########################################################################
    # GET UPID
    ###########################################################################

    UPID="$(
        printf '%s\n' "$line" |
        grep -o 'UPID:[^ ]*' ||
        true
    )"

    [ -z "$UPID" ] && continue

    ###########################################################################
    # UPID HASH
    ###########################################################################

    TASK_HASH="$(hash_upid "$UPID")"

    ###########################################################################
    # START TIME FROM UPID
    ###########################################################################

    START_HEX="$(
        printf '%s' "$UPID" |
        awk -F: '{print $6}'
    )"

    if [ -z "$START_HEX" ]; then

        log "Could not determine start time from UPID: $UPID"

        START_EPOCH=0
        RUNTIME_SECONDS=0

    elif ! [[ "$START_HEX" =~ ^[0-9A-Fa-f]+$ ]]; then

        log "Invalid UPID start hex: $UPID"

        START_EPOCH=0
        RUNTIME_SECONDS=0

    else

        START_EPOCH=$((16#$START_HEX))

        NOW_EPOCH="$(date +%s)"

        RUNTIME_SECONDS=$((NOW_EPOCH - START_EPOCH))

        if [ "$RUNTIME_SECONDS" -lt 0 ]; then
            RUNTIME_SECONDS=0
        fi

    fi

    ###########################################################################
    # RUNTIME
    ###########################################################################

    RUNTIME="$(format_runtime "$RUNTIME_SECONDS")"

    RUNTIME_MINUTES=$((RUNTIME_SECONDS / 60))

    ###########################################################################
    # START TIME
    ###########################################################################

    if [ "$START_EPOCH" -gt 0 ]; then

        START_TIME="$(
            date -d "@$START_EPOCH" '+%F %T' 2>/dev/null ||
            date '+%F %T'
        )"

    else

        START_TIME="unknown"

    fi

    CURRENT_TIME="$(date '+%F %T')"

    ###########################################################################
    # RUNNING COUNT
    ###########################################################################

    get_running_count "$UPID" "$TASK_HASH"

    ###########################################################################
    # BACKUP DETAILS
    ###########################################################################

    BACKUP_TARGET="$(get_backup_target "$UPID")"

    VMID="$(get_vm_id "$BACKUP_TARGET")"

    DATASTORE="$(get_datastore "$BACKUP_TARGET")"

    FOLDER_NAME="$(get_folder_name "$BACKUP_TARGET")"

    ###########################################################################
    # PBS TASK LOG
    ###########################################################################

    TASK_LOG="$(get_task_log "$UPID")"

    LAST_LOG_MESSAGE="$(get_last_task_log_line "$TASK_LOG")"

    LAST_LOG_TIME="$(get_last_task_log_time "$TASK_LOG")"

    ###########################################################################
    # WHY STILL RUNNING
    ###########################################################################

    WHY_RUNNING="$(determine_reason "$LAST_LOG_MESSAGE")"

    ###########################################################################
    # LONG-RUNNING FLAG
    #
    # CSV inclusion is NOT dependent on this.
    #
    # Every running task has already reached this point.
    ###########################################################################

    if [ "$RUNTIME_SECONDS" -gt "$THRESHOLD_SECONDS" ]; then

        LONG_RUNNING="YES"

        LONG_RUNNING_STATUS="EXCEEDED_5_HOURS"

    else

        LONG_RUNNING="NO"

        LONG_RUNNING_STATUS="WITHIN_5_HOURS"

    fi

    ###########################################################################
    # CSV ROW
    ###########################################################################

    {

        csv_escape "$REPORT_TIME"
        printf ','

        csv_escape "$HOSTNAME_SHORT"
        printf ','

        csv_escape "$HOSTNAME_FQDN"
        printf ','

        csv_escape "$IPADDR"
        printf ','

        csv_escape "$TOTAL_RUNNING_TASKS"
        printf ','

        csv_escape "running"
        printf ','

        # CSV cannot physically colour cells.
        # This field tells Excel/user that the row should be considered RED.
        csv_escape "RED"
        printf ','

        csv_escape "$UPID"
        printf ','

        csv_escape "$TASK_HASH"
        printf ','

        csv_escape "$VMID"
        printf ','

        csv_escape "$BACKUP_TARGET"
        printf ','

        csv_escape "$FOLDER_NAME"
        printf ','

        csv_escape "$DATASTORE"
        printf ','

        csv_escape "$START_TIME"
        printf ','

        csv_escape "$CURRENT_TIME"
        printf ','

        csv_escape "$RUNTIME"
        printf ','

        csv_escape "$RUNTIME_SECONDS"
        printf ','

        csv_escape "$RUNTIME_MINUTES"
        printf ','

        csv_escape "$RUNNING_CHECK_COUNT"
        printf ','

        csv_escape "$RUNNING_FIRST_SEEN"
        printf ','

        csv_escape "$RUNNING_LAST_SEEN"
        printf ','

        csv_escape "$LONG_RUNNING"
        printf ','

        csv_escape "5 hours"
        printf ','

        csv_escape "$LONG_RUNNING_STATUS"
        printf ','

        csv_escape "$LAST_LOG_TIME"
        printf ','

        csv_escape "$LAST_LOG_MESSAGE"
        printf ','

        csv_escape "$WHY_RUNNING"
        printf ','

        csv_escape "$TASK_LOG"
        printf ','

        csv_escape "$line"

        printf '\n'

    } >> "$CSV_FILE"

    ###########################################################################
    # LOG EVERY RUNNING TASK
    ###########################################################################

    log "Running task:"
    log "  UPID             : $UPID"
    log "  VM/CT ID         : $VMID"
    log "  Backup Target    : $BACKUP_TARGET"
    log "  Runtime          : $RUNTIME"
    log "  Check Count      : $RUNNING_CHECK_COUNT"
    log "  Long Running     : $LONG_RUNNING"
    log "  Last Log         : $LAST_LOG_MESSAGE"

    ###########################################################################
    # EXISTING LONG-RUNNING ACTION
    #
    # ONLY tasks > 5 HOURS reach this section.
    ###########################################################################

    if [ "$RUNTIME_SECONDS" -le "$THRESHOLD_SECONDS" ]; then

        continue

    fi

    ###########################################################################
    # LONG RUNNING TASK DETECTED
    ###########################################################################

    TASK_HASH="$(hash_upid "$UPID")"

    ALERT_MARKER="$ALERT_DIR/$TASK_HASH"

    ###########################################################################
    # EXISTING ALERT MARKER
    #
    # CSV was already written above.
    #
    # Therefore this marker does NOT prevent the task from appearing in CSV.
    ###########################################################################

    if [ -f "$ALERT_MARKER" ]; then

        log "Long-running task already processed for alert/stop: $UPID"

        continue

    fi

    touch "$ALERT_MARKER"

    ###########################################################################
    # RUNTIME BREAKDOWN
    ###########################################################################

    HOURS=$((RUNTIME_SECONDS / 3600))

    MINUTES=$(((RUNTIME_SECONDS % 3600) / 60))

    SECONDS_LEFT=$((RUNTIME_SECONDS % 60))

    ###########################################################################
    # LONG RUNNING LOG
    ###########################################################################

    log "==============================================================="
    log "LONG RUNNING BACKUP DETECTED"
    log "UPID      : $UPID"
    log "Target    : $BACKUP_TARGET"
    log "VM ID     : $VMID"
    log "Runtime   : ${HOURS}h ${MINUTES}m ${SECONDS_LEFT}s"
    log "Threshold : MORE THAN 5 HOURS"
    log "CSV       : $CSV_FILE"
    log "==============================================================="

    ###########################################################################
    # STOP VARIABLES
    ###########################################################################

    TASK_STOPPED=false

    STOP_OUTPUT=""

    ###########################################################################
    # CHECK IF TASK IS STILL RUNNING
    ###########################################################################

    is_running() {

        proxmox-backup-manager task list 2>/dev/null |
            grep -F "$UPID" |
            grep -q "running"

    }

    ###########################################################################
    # EXISTING STOP LOOP
    ###########################################################################

    for ((attempt=1; attempt<=MAX_STOP_ATTEMPTS; attempt++)); do

        #######################################################################
        # CHECK BEFORE STOP
        #######################################################################

        if ! is_running; then

            TASK_STOPPED=true

            log "Task already exited before stop request."

            break

        fi

        #######################################################################
        # STOP ATTEMPT
        #######################################################################

        log "Stop attempt $attempt/$MAX_STOP_ATTEMPTS"

        OUTPUT="$(
            proxmox-backup-manager task stop "$UPID" 2>&1 ||
            true
        )"

        STOP_OUTPUT+="
========== Attempt $attempt ==========
$OUTPUT
"

        sleep "$STOP_WAIT"

        #######################################################################
        # CHECK AFTER STOP
        #######################################################################

        if ! is_running; then

            TASK_STOPPED=true

            log "Task successfully stopped after attempt $attempt"

            break

        fi

    done

    ###########################################################################
    # ACTION RESULT
    ###########################################################################

    if $TASK_STOPPED; then

        ACTION_RESULT="Backup task terminated successfully."

    else

        ACTION_RESULT="FAILED TO TERMINATE AFTER ${MAX_STOP_ATTEMPTS} ATTEMPTS."

        log "$ACTION_RESULT"

    fi

    ###########################################################################
    # EMAIL SUBJECT
    ###########################################################################

    SUBJECT="[PBS ALERT] Backup exceeded 5 hours on ${HOSTNAME_SHORT}"

    ###########################################################################
    # EMAIL BODY
    ###########################################################################

    BODY_FILE="$(mktemp)"

    {

        echo "==========================================================="
        echo "          PROXMOX BACKUP SERVER ALERT"
        echo "==========================================================="
        echo

        echo "Hostname          : $HOSTNAME_FQDN"
        echo "IP Address        : $IPADDR"
        echo

        echo "Total Running     : $TOTAL_RUNNING_TASKS"
        echo "Running Checks    : $RUNNING_CHECK_COUNT"
        echo

        echo "Backup Target     : $BACKUP_TARGET"
        echo "Folder Name       : $FOLDER_NAME"
        echo "Datastore         : $DATASTORE"
        echo "VM ID             : $VMID"
        echo

        echo "UPID              : $UPID"
        echo "Started           : $START_TIME"
        echo "Current Time      : $CURRENT_TIME"
        echo "Runtime           : ${HOURS}h ${MINUTES}m ${SECONDS_LEFT}s"
        echo "Threshold         : MORE THAN 5 HOURS"
        echo

        echo "Last Log Time     : $LAST_LOG_TIME"
        echo "Last Log Message  : $LAST_LOG_MESSAGE"
        echo "Why Still Running : $WHY_RUNNING"
        echo

        echo "CSV Report        : $CSV_FILE"
        echo

        echo "Result            : $ACTION_RESULT"
        echo

        echo "==========================================================="
        echo "STOP COMMAND OUTPUT"
        echo "==========================================================="
        echo

        echo "$STOP_OUTPUT"

        echo

        echo "==========================================================="
        echo "Server Time : $(date '+%F %T')"
        echo "==========================================================="

    } > "$BODY_FILE"

    ###########################################################################
    # SEND EMAIL
    ###########################################################################

    send_alert "$SUBJECT" "$BODY_FILE"

    rm -f "$BODY_FILE"

    log "Mail notification completed."

done <<< "$RUNNING_TASKS"

###############################################################################
# FINAL REPORT INFORMATION
###############################################################################

if [ "$TOTAL_RUNNING_TASKS" -gt 0 ]; then

    log "==============================================================="
    log "CURRENT RUNNING TASK REPORT"
    log "Total running tasks : $TOTAL_RUNNING_TASKS"
    log "CSV report          : $CSV_FILE"
    log "==============================================================="

else

    log "No backup tasks are currently running."

fi

###############################################################################
# FINISH
###############################################################################

log "PBS backup monitor completed"
