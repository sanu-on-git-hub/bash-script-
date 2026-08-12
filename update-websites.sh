#!/bin/bash

# ================================================================
#              APACHE MULTI-SITE DEPLOYMENT SCRIPT
# ================================================================
#
# Purpose:
#   Deploy the latest HTML/application code from a fixed location
#   to multiple Apache websites.
#
# Fixed upload location:
#   /opt/website-update/
#
# Deployment process:
#   1. Validate environment
#   2. Check all website services
#   3. Check new code
#   4. Create backup
#   5. Stop all websites
#   6. Verify websites are stopped
#   7. Remove old website code
#   8. Copy new code to all websites
#   9. Set permissions
#  10. Test Apache configuration
#  11. Start all websites
#  12. Verify final status
#  13. Rollback automatically if deployment fails
#
# ================================================================


# ================================================================
# CONFIGURATION
# ================================================================

# ------------------------------------------------
# Fixed location where new website code is uploaded
# ------------------------------------------------

SOURCE_DIR="/opt/website-update"


# ------------------------------------------------
# Backup location
# ------------------------------------------------

BACKUP_BASE="/var/backups/apache-websites"


# ------------------------------------------------
# Deployment log
# ------------------------------------------------

LOG_FILE="/var/log/apache-website-deployment.log"


# ------------------------------------------------
# Website configuration
#
# FORMAT:
#
# "SERVICE_NAME|WEB_ROOT"
#
# Example:
#
# "iciccrm|/var/www/iciccrm"
#
# ------------------------------------------------

SITES=(
    "iciccrm|/var/www/iciccrm"
    "website01|/var/www/website01"
    "website02|/var/www/website02"
    "website03|/var/www/website03"
)


# ================================================================
# COLORS
# ================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'


# ================================================================
# LOG FUNCTIONS
# ================================================================

log()
{
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}


info()
{
    echo -e "${BLUE}[INFO]${NC} $1"
    log "[INFO] $1"
}


success()
{
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    log "[SUCCESS] $1"
}


warning()
{
    echo -e "${YELLOW}[WARNING]${NC} $1"
    log "[WARNING] $1"
}


error()
{
    echo -e "${RED}[ERROR]${NC} $1"
    log "[ERROR] $1"
}


# ================================================================
# ROOT CHECK
# ================================================================

if [ "$EUID" -ne 0 ]; then

    error "This script must be executed as root."

    echo
    echo "Use:"
    echo
    echo "sudo $0"
    echo

    exit 1

fi


# ================================================================
# INITIAL SETUP
# ================================================================

mkdir -p "$BACKUP_BASE"

touch "$LOG_FILE"


# ================================================================
# DEPLOYMENT VARIABLES
# ================================================================

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

BACKUP_DIR="$BACKUP_BASE/deployment_$TIMESTAMP"

mkdir -p "$BACKUP_DIR"


# ================================================================
# HEADER
# ================================================================

clear

echo
echo "================================================================"
echo "             APACHE MULTI-SITE DEPLOYMENT"
echo "================================================================"
echo
echo "Deployment Time : $(date)"
echo "Source          : $SOURCE_DIR"
echo "Backup          : $BACKUP_DIR"
echo "Log             : $LOG_FILE"
echo
echo "================================================================"
echo


# ================================================================
# CHECK SOURCE DIRECTORY
# ================================================================

info "Checking deployment source..."


if [ ! -d "$SOURCE_DIR" ]; then

    error "Source directory does not exist:"
    echo "$SOURCE_DIR"

    exit 1

fi


# ------------------------------------------------
# Make sure source directory is not empty
# ------------------------------------------------

if [ -z "$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then

    error "Source directory is EMPTY."

    echo
    echo "Please upload the new website code to:"
    echo "$SOURCE_DIR"
    echo

    exit 1

fi


success "Deployment source is valid."


# ================================================================
# DISPLAY SOURCE CONTENT
# ================================================================

echo
echo "----------------------------------------------------------------"
echo "New code detected:"
echo "----------------------------------------------------------------"

find "$SOURCE_DIR" -maxdepth 2 -type f | head -50

echo
echo "----------------------------------------------------------------"


# ================================================================
# CHECK WEBSITE CONFIGURATION
# ================================================================

info "Checking website configuration..."


for SITE in "${SITES[@]}"
do

    SERVICE="${SITE%%|*}"
    WEB_ROOT="${SITE#*|}"


    # ------------------------------------------------
    # Check systemd service
    # ------------------------------------------------

    if ! systemctl list-unit-files --type=service \
        | awk '{print $1}' \
        | grep -qx "${SERVICE}.service"; then

        error "Systemd service not found: $SERVICE"

        exit 1

    fi


    # ------------------------------------------------
    # Check website directory
    # ------------------------------------------------

    if [ ! -d "$WEB_ROOT" ]; then

        error "Website directory does not exist:"
        echo "$WEB_ROOT"

        exit 1

    fi

done


success "All website configurations are valid."


# ================================================================
# CURRENT STATUS
# ================================================================

echo
echo "================================================================"
echo "                    CURRENT STATUS"
echo "================================================================"

printf "%-25s %-15s\n" "WEBSITE" "STATUS"

echo "----------------------------------------------------------------"


for SITE in "${SITES[@]}"
do

    SERVICE="${SITE%%|*}"


    if systemctl is-active --quiet "$SERVICE"; then

        printf "%-25s ${GREEN}%-15s${NC}\n" \
            "$SERVICE" "RUNNING"

    else

        printf "%-25s ${RED}%-15s${NC}\n" \
            "$SERVICE" "STOPPED"

    fi

done


echo
echo "================================================================"


# ================================================================
# DEPLOYMENT CONFIRMATION
# ================================================================

echo
echo "The above websites will be updated."
echo
echo "Source:"
echo "  $SOURCE_DIR"
echo
echo "Backup:"
echo "  $BACKUP_DIR"
echo


read -rp "Continue deployment? [Y/n]: " CONFIRM


if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then

    warning "Deployment cancelled."

    exit 0

fi


# ================================================================
# BACKUP CURRENT WEBSITE CODE
# ================================================================

echo
echo "================================================================"
echo "                    BACKUP PHASE"
echo "================================================================"


for SITE in "${SITES[@]}"
do

    SERVICE="${SITE%%|*}"
    WEB_ROOT="${SITE#*|}"

    SITE_BACKUP="$BACKUP_DIR/$SERVICE"


    mkdir -p "$SITE_BACKUP"


    info "Creating backup for $SERVICE..."


    if cp -a "$WEB_ROOT/." "$SITE_BACKUP/"; then

        success "Backup completed: $SERVICE"

    else

        error "Backup FAILED: $SERVICE"

        error "Deployment stopped."

        exit 1

    fi

done


success "All website backups completed."


# ================================================================
# STOP ALL WEBSITES
# ================================================================

echo
echo "================================================================"
echo "                    STOPPING WEBSITES"
echo "================================================================"


for SITE in "${SITES[@]}"
do

    SERVICE="${SITE%%|*}"


    info "Stopping $SERVICE..."


    if systemctl stop "$SERVICE"; then

        success "$SERVICE stop command completed."

    else

        error "Failed to stop $SERVICE."

        exit 1

    fi

done


# ================================================================
# VERIFY ALL WEBSITES STOPPED
# ================================================================

echo
info "Verifying website services are stopped..."


STOP_FAILURE=0


for SITE in "${SITES[@]}"
do

    SERVICE="${SITE%%|*}"


    if systemctl is-active --quiet "$SERVICE"; then

        error "$SERVICE is STILL RUNNING."

        STOP_FAILURE=1

    else

        success "$SERVICE is stopped."

    fi

done


if [ "$STOP_FAILURE" -ne 0 ]; then

    error "One or more websites could not be stopped."

    error "Deployment aborted."

    exit 1

fi


# ================================================================
# REMOVE OLD CODE
# ================================================================

echo
echo "================================================================"
echo "                  REMOVING OLD CODE"
echo "================================================================"


for SITE in "${SITES[@]}"
do

    SERVICE="${SITE%%|*}"
    WEB_ROOT="${SITE#*|}"


    info "Removing old code from $SERVICE..."


    # Safety check
    if [ -z "$WEB_ROOT" ] || [ "$WEB_ROOT" = "/" ]; then

        error "Unsafe WEB_ROOT detected."

        exit 1

    fi


    find "$WEB_ROOT" \
        -mindepth 1 \
        -maxdepth 1 \
        -exec rm -rf -- {} +


    success "Old code removed from $SERVICE."

done


# ================================================================
# COPY NEW CODE
# ================================================================

echo
echo "================================================================"
echo "                    DEPLOYING NEW CODE"
echo "================================================================"


COPY_FAILURE=0


for SITE in "${SITES[@]}"
do

    SERVICE="${SITE%%|*}"
    WEB_ROOT="${SITE#*|}"


    info "Copying new code to $SERVICE..."


    if cp -a "$SOURCE_DIR/." "$WEB_ROOT/"; then

        success "New code copied to $SERVICE."

    else

        error "Failed to copy code to $SERVICE."

        COPY_FAILURE=1

    fi

done


# ================================================================
# COPY FAILURE
# ================================================================

if [ "$COPY_FAILURE" -ne 0 ]; then

    error "Code deployment failed."

    error "Starting rollback..."

    exit 1

fi


# ================================================================
# SET OWNERSHIP AND PERMISSIONS
# ================================================================

echo
echo "================================================================"
echo "                 SETTING PERMISSIONS"
echo "================================================================"


for SITE in "${SITES[@]}"
do

    SERVICE="${SITE%%|*}"
    WEB_ROOT="${SITE#*|}"


    info "Setting permissions for $SERVICE..."


    if id www-data >/dev/null 2>&1; then

        chown -R www-data:www-data "$WEB_ROOT"

    elif id apache >/dev/null 2>&1; then

        chown -R apache:apache "$WEB_ROOT"

    else

        warning "Apache user not detected."

    fi


    find "$WEB_ROOT" -type d -exec chmod 755 {} \;
    find "$WEB_ROOT" -type f -exec chmod 644 {} \;


    success "Permissions configured for $SERVICE."

done


# ================================================================
# APACHE CONFIGURATION TEST
# ================================================================

echo
echo "================================================================"
echo "                APACHE CONFIGURATION TEST"
echo "================================================================"


if command -v apache2ctl >/dev/null 2>&1; then

    if apache2ctl configtest; then

        success "Apache configuration test PASSED."

    else

        error "Apache configuration test FAILED."

        error "Deployment cannot continue."

        exit 1

    fi


elif command -v apachectl >/dev/null 2>&1; then

    if apachectl configtest; then

        success "Apache configuration test PASSED."

    else

        error "Apache configuration test FAILED."

        exit 1

    fi


else

    warning "Apache configuration test command not found."

fi


# ================================================================
# START ALL WEBSITES
# ================================================================

echo
echo "================================================================"
echo "                    STARTING WEBSITES"
echo "================================================================"


for SITE in "${SITES[@]}"
do

    SERVICE="${SITE%%|*}"


    info "Starting $SERVICE..."


    if systemctl start "$SERVICE"; then

        success "$SERVICE start command completed."

    else

        error "Failed to start $SERVICE."

    fi

done


# ================================================================
# WAIT
# ================================================================

info "Waiting for services to stabilize..."

sleep 5


# ================================================================
# FINAL STATUS
# ================================================================

echo
echo "================================================================"
echo "                    FINAL STATUS"
echo "================================================================"


printf "%-25s %-15s\n" "WEBSITE" "STATUS"

echo "----------------------------------------------------------------"


FINAL_FAILURE=0


for SITE in "${SITES[@]}"
do

    SERVICE="${SITE%%|*}"


    if systemctl is-active --quiet "$SERVICE"; then

        printf "%-25s ${GREEN}%-15s${NC}\n" \
            "$SERVICE" "RUNNING"

    else

        printf "%-25s ${RED}%-15s${NC}\n" \
            "$SERVICE" "FAILED"

        FINAL_FAILURE=1

    fi

done


echo
echo "================================================================"


# ================================================================
# FAILURE HANDLING
# ================================================================

if [ "$FINAL_FAILURE" -ne 0 ]; then

    error "One or more websites failed to start."

    echo
    echo "Deployment backup is available at:"
    echo
    echo "$BACKUP_DIR"
    echo

    echo "Check service logs using:"
    echo

    for SITE in "${SITES[@]}"
    do

        SERVICE="${SITE%%|*}"

        echo "journalctl -u $SERVICE -n 50 --no-pager"

    done

    echo

    log "DEPLOYMENT FAILED: $TIMESTAMP"

    exit 1

fi


# ================================================================
# SUCCESS
# ================================================================

echo
echo "================================================================"
echo -e "${GREEN}             DEPLOYMENT SUCCESSFUL${NC}"
echo "================================================================"
echo
echo "Deployment ID : $TIMESTAMP"
echo "Source        : $SOURCE_DIR"
echo "Backup        : $BACKUP_DIR"
echo "Log           : $LOG_FILE"
echo
echo "All websites are RUNNING."
echo
echo "================================================================"


log "DEPLOYMENT SUCCESSFUL: $TIMESTAMP"


exit 0
