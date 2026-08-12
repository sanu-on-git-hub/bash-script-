#!/bin/bash

##############################
# Configuration
##############################
DISK_THRESHOLD=52

##############################
# Disk Usage Calculation
##############################
FILESYSTEMS=$(df -P -x tmpfs -x devtmpfs -x overlay 2>/dev/null)

MAX_USAGE=$(echo "$FILESYSTEMS" | awk '
NR>1 {
    gsub("%","",$5)
    if($5+0 > max)
        max=$5+0
}
END {
    print max+0
}
')

if [ "$MAX_USAGE" -ge "$DISK_THRESHOLD" ]; then
    STATUS=1
else
    STATUS=0
fi

##############################
# Generate Report
##############################
generate_report()
{
cat <<EOF
=====================================================================
                     DISK UTILIZATION REPORT
=====================================================================

Host Name        : $(hostname)
Generated        : $(date '+%Y-%m-%d %H:%M:%S')

Disk Threshold   : ${DISK_THRESHOLD}%
Highest Usage    : ${MAX_USAGE}%
Status           : $( [ "$STATUS" -eq 1 ] && echo "WARNING" || echo "OK" )

---------------------------------------------------------------------
FILESYSTEM USAGE
---------------------------------------------------------------------
$(df -hP -x tmpfs -x devtmpfs -x overlay 2>/dev/null)

=====================================================================
EOF
}

##############################
# Output Modes
##############################
case "$1" in
raw)
    python3 -c '
import json
import subprocess

status = int("'"$STATUS"'")
usage = int("'"$MAX_USAGE"'")

report = subprocess.check_output(
    ["/bin/sh", "/usr/local/bin/disk3_monitor.sh", "report"]
).decode("utf-8")

output = {
    "status": status,
    "usage": usage,
    "report": report
}

print(json.dumps(output))
'
;;
status)
    echo "$STATUS"
;;
usage)
    echo "$MAX_USAGE"
;;
report)
    generate_report
;;
*)
    echo "Usage: $0 {raw|status|usage|report}"
    exit 1
;;
esac
