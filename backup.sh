#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

LOCKFILE="/tmp/pbs_backup_monitor.lock"
LOGFILE="/var/log/pbs_backup_monitor.log"
STATE_DIR="/var/lib/pbs-backup-monitor"
ALERT_DIR="$STATE_DIR/alerted"
REPORT_DIR="$STATE_DIR/reports"

###############################################################################
# CONFIGURATION
###############################################################################

# Task must be RUNNING for MORE THAN 5 HOURS
THRESHOLD_MINUTES=300
THRESHOLD_SECONDS=$((THRESHOLD_MINUTES * 60))

# Space-separated recipients
RECIPIENTS=("systemadmin@1point1.com")

HOSTNAME_SHORT="$(hostname 2>/dev/null || echo unknown)"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)"
IPADDR="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
[ -z "${IPADDR:-}" ] && IPADDR="unknown"

MAIL_FROM="root@ogsrvcmpbs.1point1.in"

###############################################################################
# CREATE DIRECTORIES
###############################################################################

mkdir -p "$(dirname "$LOGFILE")"
mkdir -p "$ALERT_DIR"
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
    printf '%s - %s\n' "$(date '+%F %T')" "$*" >> "$LOGFILE"
}

###############################################################################
# PROPER CSV ESCAPE
###############################################################################

csv_escape() {

    local value="${1:-}"

    # Remove CR/LF so one task always remains one CSV row
    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"

    # Escape double quotes according to CSV standard
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

    if command -v mail >/dev/null 2>&1; then

        for recipient in "${RECIPIENTS[@]}"; do

            mail -s "$subject" "$recipient" < "$bodyfile" \
                || log "mail failed for $recipient"

        done

        return 0
    fi

    if command -v mailx >/dev/null 2>&1; then

        for recipient in "${RECIPIENTS[@]}"; do

            mailx -s "$subject" "$recipient" < "$bodyfile" \
                || log "mailx failed for $recipient"

        done

        return 0
    fi

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

            sendmail -t < "$tmpmsg" \
                || log "sendmail failed for $recipient"

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
# GET TASK LOG
###############################################################################

get_task_log() {

    local upid="$1"

    local task_log

    task_log="$(
        proxmox-backup-manager task log "$upid" 2>/dev/null ||
        true
    )"

    if [ -z "$task_log" ]; then

        printf '%s' "No PBS task log available"

        return
    fi

    printf '%s\n' "$task_log" |
        sed '/^[[:space:]]*$/d' |
        tail -n 1
}

###############################################################################
# GET LAST LOG TIME
###############################################################################

get_task_log_time() {

    local upid="$1"

    local task_log
    local last_line

    task_log="$(
        proxmox-backup-manager task log "$upid" 2>/dev/null ||
        true
    )"

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
                "Task may be waiting on a lock"

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
# GET PROCESS INFORMATION
###############################################################################

get_process_info() {

    local pid="$1"

    PROCESS_STATE="unknown"
    PROCESS_CPU="unknown"
    PROCESS_MEMORY="unknown"
    PROCESS_COMMAND="unknown"
    PROCESS_EXE="unknown"
    PROCESS_CWD="unknown"

    if [ -z "$pid" ]; then
        return
    fi

    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        return
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        return
    fi

    PROCESS_STATE="$(
        ps -p "$pid" -o state= 2>/dev/null |
        xargs ||
        true
    )"

    PROCESS_CPU="$(
        ps -p "$pid" -o %cpu= 2>/dev/null |
        xargs ||
        true
    )"

    PROCESS_MEMORY="$(
        ps -p "$pid" -o %mem= 2>/dev/null |
        xargs ||
        true
    )"

    PROCESS_COMMAND="$(
        ps -p "$pid" -o args= 2>/dev/null |
        xargs ||
        true
    )"

    if [ -e "/proc/$pid/exe" ]; then

        PROCESS_EXE="$(
            readlink -f "/proc/$pid/exe" 2>/dev/null ||
            echo unknown
        )"

    fi

    if [ -e "/proc/$pid/cwd" ]; then

        PROCESS_CWD="$(
            readlink -f "/proc/$pid/cwd" 2>/dev/null ||
            echo unknown
        )"

    fi

    [ -z "$PROCESS_STATE" ] && PROCESS_STATE="unknown"
    [ -z "$PROCESS_CPU" ] && PROCESS_CPU="unknown"
    [ -z "$PROCESS_MEMORY" ] && PROCESS_MEMORY="unknown"
    [ -z "$PROCESS_COMMAND" ] && PROCESS_COMMAND="unknown"
}

###############################################################################
# START
###############################################################################

log "PBS backup monitor started on $HOSTNAME_FQDN ($IPADDR)"

###############################################################################
# CURRENT RUNNING TASKS
###############################################################################

RUNNING_TASKS="$(
    proxmox-backup-manager task list 2>/dev/null |
    grep 'backup:' |
    grep 'running' ||
    true
)"

if [ -n "$RUNNING_TASKS" ]; then

    TOTAL_RUNNING_TASKS="$(
        printf '%s\n' "$RUNNING_TASKS" |
        wc -l |
        xargs
    )"

else

    TOTAL_RUNNING_TASKS=0

fi

log "Total running backup tasks: $TOTAL_RUNNING_TASKS"

###############################################################################
# CSV REPORT
#
# IMPORTANT:
# CSV contains ONLY tasks:
#
#       status = running
#       runtime > 5 hours
#
###############################################################################

REPORT_TIMESTAMP="$(date '+%F_%H%M%S')"

CSV_FILE="$REPORT_DIR/pbs_tasks_running_more_than_5_hours_${REPORT_TIMESTAMP}.csv"

LONG_RUNNING_COUNT=0

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
    # GET START TIME FROM UPID
    ###########################################################################

    START_HEX="$(
        printf '%s' "$UPID" |
        awk -F: '{print $6}'
    )"

    [ -z "$START_HEX" ] && continue

    if ! [[ "$START_HEX" =~ ^[0-9A-Fa-f]+$ ]]; then

        log "Skipping invalid UPID start hex: $UPID"

        continue

    fi

    START_EPOCH=$((16#$START_HEX))

    NOW_EPOCH="$(date +%s)"

    RUNTIME_SECONDS=$((NOW_EPOCH - START_EPOCH))

    ###########################################################################
    # ONLY MORE THAN 5 HOURS
    #
    # 5:00:00 exactly = NOT included
    # 5:00:01        = included
    ###########################################################################

    if [ "$RUNTIME_SECONDS" -le "$THRESHOLD_SECONDS" ]; then

        continue

    fi

    ###########################################################################
    # LONG RUNNING TASK FOUND
    ###########################################################################

    LONG_RUNNING_COUNT=$((LONG_RUNNING_COUNT + 1))

    ###########################################################################
    # TASK DETAILS
    ###########################################################################

    BACKUP_TARGET="$(get_backup_target "$UPID")"

    VMID="$(get_vm_id "$BACKUP_TARGET")"

    DATASTORE="$(get_datastore "$BACKUP_TARGET")"

    FOLDER_NAME="$BACKUP_TARGET"

    START_TIME="$(
        date -d "@$START_EPOCH" '+%F %T' 2>/dev/null ||
        date '+%F %T'
    )"

    CURRENT_TIME="$(date '+%F %T')"

    RUNTIME="$(format_runtime "$RUNTIME_SECONDS")"

    RUNTIME_MINUTES=$((RUNTIME_SECONDS / 60))

    ###########################################################################
    # DEFAULT TASK INFORMATION
    ###########################################################################

    NODE="$HOSTNAME_FQDN"
    PID="unknown"
    USER="unknown"
    WORKER_TYPE="backup"
    WORKER_ID="$BACKUP_TARGET"

    ###########################################################################
    # BEST-EFFORT PID EXTRACTION FROM CURRENT TASK LIST
    ###########################################################################

    PID_FOUND="$(
        printf '%s\n' "$line" |
        grep -oE '[[:space:]][0-9]{2,}[[:space:]]' |
        head -n 1 |
        xargs ||
        true
    )"

    if [ -n "$PID_FOUND" ]; then

        PID="$PID_FOUND"

    fi

    ###########################################################################
    # PROCESS INFORMATION
    ###########################################################################

    get_process_info "$PID"

    ###########################################################################
    # PBS TASK LOG
    ###########################################################################

    LAST_LOG_MESSAGE="$(get_task_log "$UPID")"

    LAST_LOG_TIME="$(get_task_log_time "$UPID")"

    ###########################################################################
    # WHY IS IT STILL RUNNING?
    ###########################################################################

    WHY_RUNNING="$(determine_reason "$LAST_LOG_MESSAGE")"

    ###########################################################################
    # CREATE CSV HEADER ON FIRST LONG-RUNNING TASK
    ###########################################################################

    if [ "$LONG_RUNNING_COUNT" -eq 1 ]; then

        {

            csv_escape "Report_Time"
            printf ','

            csv_escape "Hostname"
            printf ','

            csv_escape "IP_Address"
            printf ','

            csv_escape "Total_Running_Tasks"
            printf ','

            csv_escape "Long_Running_Task"
            printf ','

            csv_escape "UPID"
            printf ','

            csv_escape "Node"
            printf ','

            csv_escape "PID"
            printf ','

            csv_escape "User"
            printf ','

            csv_escape "Worker_Type"
            printf ','

            csv_escape "Worker_ID"
            printf ','

            csv_escape "VM_CT_ID"
            printf ','

            csv_escape "Backup_Target"
            printf ','

            csv_escape "Datastore"
            printf ','

            csv_escape "Folder_Name"
            printf ','

            csv_escape "Task_Start_Time"
            printf ','

            csv_escape "Current_Time"
            printf ','

            csv_escape "Runtime"
            printf ','

            csv_escape "Runtime_Minutes"
            printf ','

            csv_escape "Task_Status"
            printf ','

            csv_escape "Process_State"
            printf ','

            csv_escape "Process_CPU_Percent"
            printf ','

            csv_escape "Process_Memory_Percent"
            printf ','

            csv_escape "Process_Command"
            printf ','

            csv_escape "Process_EXE"
            printf ','

            csv_escape "Process_CWD"
            printf ','

            csv_escape "Last_Log_Time"
            printf ','

            csv_escape "Last_Log_Message"
            printf ','

            csv_escape "Why_Still_Running"
            printf ','

            csv_escape "Threshold_Hours"
            printf ','

            csv_escape "Server_Time"

            printf '\n'

        } > "$CSV_FILE"

    fi

    ###########################################################################
    # WRITE ONE ROW FOR THIS LONG-RUNNING TASK
    ###########################################################################

    {

        csv_escape "$(date '+%F %T')"
        printf ','

        csv_escape "$HOSTNAME_FQDN"
        printf ','

        csv_escape "$IPADDR"
        printf ','

        csv_escape "$TOTAL_RUNNING_TASKS"
        printf ','

        csv_escape "YES"
        printf ','

        csv_escape "$UPID"
        printf ','

        csv_escape "$NODE"
        printf ','

        csv_escape "$PID"
        printf ','

        csv_escape "$USER"
        printf ','

        csv_escape "$WORKER_TYPE"
        printf ','

        csv_escape "$WORKER_ID"
        printf ','

        csv_escape "$VMID"
        printf ','

        csv_escape "$BACKUP_TARGET"
        printf ','

        csv_escape "$DATASTORE"
        printf ','

        csv_escape "$FOLDER_NAME"
        printf ','

        csv_escape "$START_TIME"
        printf ','

        csv_escape "$CURRENT_TIME"
        printf ','

        csv_escape "$RUNTIME"
        printf ','

        csv_escape "$RUNTIME_MINUTES"
        printf ','

        csv_escape "running"
        printf ','

        csv_escape "$PROCESS_STATE"
        printf ','

        csv_escape "$PROCESS_CPU"
        printf ','

        csv_escape "$PROCESS_MEMORY"
        printf ','

        csv_escape "$PROCESS_COMMAND"
        printf ','

        csv_escape "$PROCESS_EXE"
        printf ','

        csv_escape "$PROCESS_CWD"
        printf ','

        csv_escape "$LAST_LOG_TIME"
        printf ','

        csv_escape "$LAST_LOG_MESSAGE"
        printf ','

        csv_escape "$WHY_RUNNING"
        printf ','

        csv_escape "5"
        printf ','

        csv_escape "$(date '+%F %T')"

        printf '\n'

    } >> "$CSV_FILE"

    ###########################################################################
    # EXISTING ALERT / STOP LOGIC
    #
    # IMPORTANT:
    # CSV has already been generated.
    #
    # Therefore an existing alert marker does NOT prevent this task from
    # appearing in the CSV.
    ###########################################################################

    TASK_HASH="$(hash_upid "$UPID")"

    ALERT_MARKER="$ALERT_DIR/$TASK_HASH"

    if [ -f "$ALERT_MARKER" ]; then

        log "Already processed this task for alert/stop, skipping action: $UPID"

        continue

    fi

    touch "$ALERT_MARKER"

    ###########################################################################
    # EXISTING LONG-RUNNING BACKUP ACTION
    ###########################################################################

    HOURS=$((RUNTIME_SECONDS / 3600))
    MINUTES=$(((RUNTIME_SECONDS % 3600) / 60))
    SECONDS_LEFT=$((RUNTIME_SECONDS % 60))

    log "==============================================================="
    log "Long running backup detected"
    log "UPID      : $UPID"
    log "Target    : $BACKUP_TARGET"
    log "Runtime   : ${HOURS}h ${MINUTES}m ${SECONDS_LEFT}s"
    log "Threshold : MORE THAN ${THRESHOLD_MINUTES} minutes"
    log "CSV       : $CSV_FILE"

    ###########################################################################
    # EXISTING STOP SETTINGS
    ###########################################################################

    MAX_STOP_ATTEMPTS=12
    STOP_WAIT=15

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

        if ! is_running; then

            TASK_STOPPED=true

            log "Task already exited before stop request."

            break

        fi

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
    # EMAIL
    ###########################################################################

    SUBJECT="[PBS ALERT] Backup exceeded 5 hours on ${HOSTNAME_SHORT}"

    BODY_FILE="$(mktemp)"

    {

        echo "==========================================================="
        echo "          PROXMOX BACKUP SERVER ALERT"
        echo "==========================================================="
        echo

        echo "Hostname      : $HOSTNAME_FQDN"
        echo "IP Address    : $IPADDR"
        echo

        echo "Total Running : $TOTAL_RUNNING_TASKS"
        echo

        echo "Backup Target : $BACKUP_TARGET"
        echo "VM ID         : $VMID"
        echo

        echo "UPID          : $UPID"
        echo "Started       : $START_TIME"
        echo "Runtime       : ${HOURS}h ${MINUTES}m ${SECONDS_LEFT}s"
        echo "Threshold     : MORE THAN 5 HOURS"
        echo

        echo "Last Log      : $LAST_LOG_MESSAGE"
        echo "Why Running   : $WHY_RUNNING"
        echo

        echo "CSV Report    : $CSV_FILE"
        echo

        echo "Result        : $ACTION_RESULT"
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

    send_alert "$SUBJECT" "$BODY_FILE"

    rm -f "$BODY_FILE"

    log "Mail notification completed."

done < <(
    proxmox-backup-manager task list 2>/dev/null |
    grep 'backup:' |
    grep 'running' ||
    true
)

###############################################################################
# FINAL REPORT
###############################################################################

if [ "$LONG_RUNNING_COUNT" -gt 0 ]; then

    log "==============================================================="
    log "CSV REPORT GENERATED"
    log "Total running tasks : $TOTAL_RUNNING_TASKS"
    log "Tasks > 5 hours    : $LONG_RUNNING_COUNT"
    log "CSV file            : $CSV_FILE"
    log "==============================================================="

else

    log "No backup task has been running for more than 5 hours."

fi

###############################################################################
# FINISH
###############################################################################

log "PBS backup monitor completed"
