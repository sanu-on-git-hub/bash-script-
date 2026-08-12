#!/bin/bash

# ================================================================
#       APACHE AUTOMATIC MULTI-SITE WEBSITE DEPLOYMENT
# ================================================================
#
# Automatically detects Apache VirtualHosts and their DocumentRoots.
#
# Deployment source:
#       /opt/website-update/
#
# Apache configuration:
#       /etc/apache2/sites-enabled/
#
# Backup:
#       /var/backups/apache-websites/
#
# Log:
#       /var/log/apache-website-deployment.log
#
# Usage:
#       sudo ./apache-deploy.sh
#
# Dry run:
#       sudo ./apache-deploy.sh --dry-run
#
# ================================================================


# ================================================================
# CONFIGURATION
# ================================================================

SOURCE_DIR="/opt/website-update"

BACKUP_BASE="/var/backups/apache-websites"

LOG_FILE="/var/log/apache-website-deployment.log"

LOCK_FILE="/var/run/apache-website-deployment.lock"

APACHE_SERVICE="apache2"

APACHE_CONFIG_DIR="/etc/apache2/sites-enabled"

# Number of old backups to keep
BACKUPS_TO_KEEP=10

# Automatically rollback if deployment fails
ROLLBACK_ENABLED=true

# Show detected websites before deployment
SHOW_DETECTED_SITES=true

# Default mode
DRY_RUN=false


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
# FUNCTIONS
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

    echo
    echo -e "${RED}[ERROR]${NC} Script must be executed as root."
    echo
    echo "Use:"
    echo
    echo "sudo $0"
    echo

    exit 1

fi


# ================================================================
# ARGUMENT CHECK
# ================================================================

if [ "$1" = "--dry-run" ]; then

    DRY_RUN=true

fi


# ================================================================
# REQUIRED COMMAND CHECK
# ================================================================

REQUIRED_COMMANDS=(
    systemctl
    find
    cp
    mv
    sort
    awk
    grep
    sed
    date
)


for CMD in "${REQUIRED_COMMANDS[@]}"
do

    if ! command -v "$CMD" >/dev/null 2>&1; then

        error "Required command not found: $CMD"

        exit 1

    fi

done


# ================================================================
# APACHE COMMAND DETECTION
# ================================================================

if command -v apache2ctl >/dev/null 2>&1; then

    APACHECTL="apache2ctl"

elif command -v apachectl >/dev/null 2>&1; then

    APACHECTL="apachectl"

else

    error "Apache control command not found."

    exit 1

fi


# ================================================================
# CREATE REQUIRED DIRECTORIES
# ================================================================

mkdir -p "$BACKUP_BASE"

touch "$LOG_FILE"


# ================================================================
# DEPLOYMENT ID
# ================================================================

DEPLOYMENT_ID=$(date '+%Y%m%d_%H%M%S')

BACKUP_DIR="$BACKUP_BASE/deployment_$DEPLOYMENT_ID"


# ================================================================
# LOCK
# ================================================================

if [ -e "$LOCK_FILE" ]; then

    error "Another deployment appears to be running."

    echo
    echo "Lock file:"
    echo "$LOCK_FILE"
    echo

    exit 1

fi


trap 'rm -f "$LOCK_FILE"' EXIT

touch "$LOCK_FILE"


# ================================================================
# HEADER
# ================================================================

clear

echo
echo "================================================================"
echo "        APACHE AUTOMATIC MULTI-SITE DEPLOYMENT"
echo "================================================================"
echo
echo "Deployment ID : $DEPLOYMENT_ID"
echo "Source        : $SOURCE_DIR"
echo "Apache        : $APACHE_SERVICE"
echo "Backup        : $BACKUP_DIR"
echo "Log           : $LOG_FILE"
echo

if [ "$DRY_RUN" = true ]; then

    echo -e "${YELLOW}MODE           : DRY RUN${NC}"

else

    echo "MODE           : LIVE DEPLOYMENT"

fi

echo
echo "================================================================"
echo


# ================================================================
# SOURCE DIRECTORY CHECK
# ================================================================

info "Checking deployment source..."


if [ ! -d "$SOURCE_DIR" ]; then

    error "Source directory does not exist:"
    echo "$SOURCE_DIR"

    exit 1

fi


# ================================================================
# SOURCE EMPTY CHECK
# ================================================================

if [ -z "$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then

    error "Source directory is EMPTY."

    echo
    echo "Upload the new website code into:"
    echo
    echo "$SOURCE_DIR"
    echo

    exit 1

fi


success "Deployment source is available."


# ================================================================
# DISPLAY SOURCE CONTENT
# ================================================================

echo
echo "----------------------------------------------------------------"
echo "NEW DEPLOYMENT CONTENT"
echo "----------------------------------------------------------------"

find "$SOURCE_DIR" -maxdepth 2 -type f | sort | head -50

echo
echo "----------------------------------------------------------------"


# ================================================================
# CHECK APACHE SERVICE
# ================================================================

info "Checking Apache service..."


if ! systemctl list-unit-files \
    | awk '{print $1}' \
    | grep -qx "${APACHE_SERVICE}.service"; then

    error "Apache systemd service not found:"
    echo "$APACHE_SERVICE"

    exit 1

fi


success "Apache service detected."


# ================================================================
# DETECT APACHE VIRTUAL HOSTS
# ================================================================

info "Detecting Apache VirtualHosts..."


if [ ! -d "$APACHE_CONFIG_DIR" ]; then

    error "Apache sites-enabled directory not found:"
    echo "$APACHE_CONFIG_DIR"

    exit 1

fi


# Temporary files

DETECTED_FILE=$(mktemp)
SERVER_FILE=$(mktemp)
ROOT_FILE=$(mktemp)


# Cleanup temporary files on exit

cleanup_temp()
{
    rm -f "$DETECTED_FILE"
    rm -f "$SERVER_FILE"
    rm -f "$ROOT_FILE"
}

trap cleanup_temp EXIT


# ================================================================
# FIND ENABLED APACHE CONFIG FILES
# ================================================================

CONFIG_FILES=$(find "$APACHE_CONFIG_DIR" \
    -maxdepth 1 \
    -type f \
    \( -name "*.conf" -o -name "*.vhost" \) \
    | sort)


if [ -z "$CONFIG_FILES" ]; then

    error "No Apache VirtualHost configuration files found."

    exit 1

fi


# ================================================================
# EXTRACT DOCUMENT ROOTS
# ================================================================

while IFS= read -r CONFIG
do

    [ -z "$CONFIG" ] && continue


    awk '
    BEGIN {
        IGNORECASE=1
    }

    /^[[:space:]]*DocumentRoot[[:space:]]+/ {

        gsub(/"/, "", $2)

        print $2
    }
    ' "$CONFIG" >> "$ROOT_FILE"


done <<< "$CONFIG_FILES"


# ================================================================
# REMOVE DUPLICATES
# ================================================================

sort -u "$ROOT_FILE" -o "$ROOT_FILE"


# ================================================================
# REMOVE INVALID ROOTS
# ================================================================

grep '^/' "$ROOT_FILE" > "$ROOT_FILE.tmp"

mv "$ROOT_FILE.tmp" "$ROOT_FILE"


# ================================================================
# CHECK DETECTED DOCUMENT ROOTS
# ================================================================

if [ ! -s "$ROOT_FILE" ]; then

    error "No Apache DocumentRoot detected."

    exit 1

fi


# ================================================================
# BUILD WEBSITE LIST
# ================================================================

SITE_COUNT=0


while IFS= read -r WEB_ROOT
do

    [ -z "$WEB_ROOT" ] && continue


    if [ ! -d "$WEB_ROOT" ]; then

        warning "DocumentRoot does not currently exist:"
        echo "$WEB_ROOT"

        continue

    fi


    # Extract ServerName associated with this DocumentRoot

    SERVER_NAME=$(grep -R -B 30 -A 5 \
        -iE "^[[:space:]]*DocumentRoot[[:space:]]+$WEB_ROOT([[:space:]]|$)" \
        "$APACHE_CONFIG_DIR" 2>/dev/null \
        | grep -iE "^[[:space:]]*ServerName[[:space:]]+" \
        | tail -1 \
        | awk '{print $2}')


    if [ -z "$SERVER_NAME" ]; then

        SERVER_NAME=$(basename "$WEB_ROOT")

    fi


    echo "$SERVER_NAME|$WEB_ROOT" >> "$DETECTED_FILE"

    SITE_COUNT=$((SITE_COUNT + 1))


done < "$ROOT_FILE"


# ================================================================
# CHECK NUMBER OF SITES
# ================================================================

if [ "$SITE_COUNT" -eq 0 ]; then

    error "No valid Apache websites were detected."

    exit 1

fi


# ================================================================
# DISPLAY DETECTED SITES
# ================================================================

echo
echo "================================================================"
echo "                DETECTED APACHE WEBSITES"
echo "================================================================"

printf "%-35s %-60s\n" "SITE" "DOCUMENT ROOT"

echo "----------------------------------------------------------------"


while IFS='|' read -r SITE_NAME WEB_ROOT
do

    printf "%-35s %-60s\n" \
        "$SITE_NAME" \
        "$WEB_ROOT"

done < "$DETECTED_FILE"


echo "----------------------------------------------------------------"

echo
echo "Total detected sites: $SITE_COUNT"

echo
echo "================================================================"


# ================================================================
# APACHE CONFIGURATION CHECK
# ================================================================

info "Testing current Apache configuration..."


if ! "$APACHECTL" configtest; then

    error "Current Apache configuration is INVALID."

    error "Deployment stopped."

    exit 1

fi


success "Current Apache configuration is valid."


# ================================================================
# DRY RUN
# ================================================================

if [ "$DRY_RUN" = true ]; then

    echo
    echo "================================================================"
    echo -e "${YELLOW}                 DRY RUN COMPLETE${NC}"
    echo "================================================================"
    echo
    echo "No files were changed."
    echo "No websites were stopped."
    echo "No websites were started."
    echo
    echo "Detected sites:"
    echo

    cat "$DETECTED_FILE"

    echo
    exit 0

fi


# ================================================================
# CONFIRMATION
# ================================================================

echo
echo -e "${YELLOW}WARNING:${NC}"
echo
echo "The contents of the detected DocumentRoot directories"
echo "will be replaced with the contents of:"
echo
echo "    $SOURCE_DIR"
echo
echo "A backup will be created before deletion."
echo
echo "Number of websites:"
echo
echo "    $SITE_COUNT"
echo


read -rp "Continue deployment? [Y/n]: " CONFIRM


if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then

    warning "Deployment cancelled by user."

    exit 0

fi


# ================================================================
# CREATE BACKUP DIRECTORY
# ================================================================

mkdir -p "$BACKUP_DIR"


# ================================================================
# BACKUP ALL WEBSITES
# ================================================================

echo
echo "================================================================"
echo "                    BACKUP PHASE"
echo "================================================================"


BACKUP_FAILURE=false


while IFS='|' read -r SITE_NAME WEB_ROOT
do

    SAFE_NAME=$(echo "$SITE_NAME" | sed 's/[^a-zA-Z0-9._-]/_/g')

    SITE_BACKUP="$BACKUP_DIR/$SAFE_NAME"

    mkdir -p "$SITE_BACKUP"


    info "Backing up:"
    echo "    $WEB_ROOT"
    echo "    -> $SITE_BACKUP"


    if cp -a "$WEB_ROOT/." "$SITE_BACKUP/"; then

        success "Backup completed: $SITE_NAME"

    else

        error "Backup FAILED: $SITE_NAME"

        BACKUP_FAILURE=true

    fi


done < "$DETECTED_FILE"


# ================================================================
# BACKUP FAILURE
# ================================================================

if [ "$BACKUP_FAILURE" = true ]; then

    error "One or more backups failed."

    error "Deployment ABORTED."

    exit 1

fi


success "All website backups completed."


# ================================================================
# STOP APACHE
# ================================================================

echo
echo "================================================================"
echo "                    STOPPING APACHE"
echo "================================================================"


info "Stopping Apache..."


if ! systemctl stop "$APACHE_SERVICE"; then

    error "Failed to stop Apache."

    exit 1

fi


sleep 2


# ================================================================
# VERIFY APACHE STOPPED
# ================================================================

if systemctl is-active --quiet "$APACHE_SERVICE"; then

    error "Apache is still running."

    error "Deployment aborted."

    systemctl start "$APACHE_SERVICE"

    exit 1

fi


success "Apache stopped successfully."


# ================================================================
# DELETE OLD WEBSITE CONTENT
# ================================================================

echo
echo "================================================================"
echo "                 REMOVING OLD WEBSITE CODE"
echo "================================================================"


DELETE_FAILURE=false


while IFS='|' read -r SITE_NAME WEB_ROOT
do

    info "Removing old content:"
    echo "    $WEB_ROOT"


    # ------------------------------------------------------------
    # SAFETY CHECK
    # ------------------------------------------------------------

    if [ -z "$WEB_ROOT" ]; then

        error "Empty DocumentRoot detected."

        DELETE_FAILURE=true

        continue

    fi


    if [ "$WEB_ROOT" = "/" ]; then

        error "DANGEROUS DocumentRoot detected: /"

        DELETE_FAILURE=true

        continue

    fi


    if [ "$WEB_ROOT" = "/var/www" ]; then

        error "DANGEROUS broad DocumentRoot detected: /var/www"

        DELETE_FAILURE=true

        continue

    fi


    # ------------------------------------------------------------
    # DELETE CONTENT ONLY
    # ------------------------------------------------------------

    if find "$WEB_ROOT" \
        -mindepth 1 \
        -maxdepth 1 \
        -exec rm -rf -- {} +; then

        success "Old content removed: $SITE_NAME"

    else

        error "Failed to remove old content: $SITE_NAME"

        DELETE_FAILURE=true

    fi


done < "$DETECTED_FILE"


# ================================================================
# DELETE FAILURE
# ================================================================

if [ "$DELETE_FAILURE" = true ]; then

    error "Website cleanup failed."

    error "Starting rollback..."

    # Start Apache first
    systemctl start "$APACHE_SERVICE"

    exit 1

fi


# ================================================================
# COPY NEW WEBSITE CODE
# ================================================================

echo
echo "================================================================"
echo "                    DEPLOYING NEW CODE"
echo "================================================================"


COPY_FAILURE=false


while IFS='|' read -r SITE_NAME WEB_ROOT
do

    info "Deploying code to:"
    echo "    $SITE_NAME"
    echo "    $WEB_ROOT"


    if cp -a "$SOURCE_DIR/." "$WEB_ROOT/"; then

        success "Code deployed: $SITE_NAME"

    else

        error "Code deployment FAILED: $SITE_NAME"

        COPY_FAILURE=true

    fi


done < "$DETECTED_FILE"


# ================================================================
# COPY FAILURE
# ================================================================

if [ "$COPY_FAILURE" = true ]; then

    error "One or more websites failed during deployment."

    if [ "$ROLLBACK_ENABLED" = true ]; then

        error "Rollback will be attempted."

        # --------------------------------------------------------
        # ROLLBACK
        # --------------------------------------------------------

        while IFS='|' read -r SITE_NAME WEB_ROOT
        do

            SAFE_NAME=$(echo "$SITE_NAME" | sed 's/[^a-zA-Z0-9._-]/_/g')

            SITE_BACKUP="$BACKUP_DIR/$SAFE_NAME"


            if [ -d "$SITE_BACKUP" ]; then

                info "Restoring $SITE_NAME..."

                find "$WEB_ROOT" \
                    -mindepth 1 \
                    -maxdepth 1 \
                    -exec rm -rf -- {} +


                cp -a "$SITE_BACKUP/." "$WEB_ROOT/"


                success "Rollback completed: $SITE_NAME"

            fi

        done < "$DETECTED_FILE"

    fi


    systemctl start "$APACHE_SERVICE"

    exit 1

fi


# ================================================================
# SET PERMISSIONS
# ================================================================

echo
echo "================================================================"
echo "                    SETTING PERMISSIONS"
echo "================================================================"


while IFS='|' read -r SITE_NAME WEB_ROOT
do

    info "Setting permissions: $SITE_NAME"


    if id www-data >/dev/null 2>&1; then

        chown -R www-data:www-data "$WEB_ROOT"

    elif id apache >/dev/null 2>&1; then

        chown -R apache:apache "$WEB_ROOT"

    else

        warning "Apache user could not be detected."

    fi


    find "$WEB_ROOT" \
        -type d \
        -exec chmod 755 {} \;


    find "$WEB_ROOT" \
        -type f \
        -exec chmod 644 {} \;


    success "Permissions configured: $SITE_NAME"


done < "$DETECTED_FILE"


# ================================================================
# APACHE CONFIGURATION TEST
# ================================================================

echo
echo "================================================================"
echo "                APACHE CONFIGURATION TEST"
echo "================================================================"


if ! "$APACHECTL" configtest; then

    error "Apache configuration test FAILED."

    if [ "$ROLLBACK_ENABLED" = true ]; then

        error "Starting rollback..."

        while IFS='|' read -r SITE_NAME WEB_ROOT
        do

            SAFE_NAME=$(echo "$SITE_NAME" | sed 's/[^a-zA-Z0-9._-]/_/g')

            SITE_BACKUP="$BACKUP_DIR/$SAFE_NAME"


            if [ -d "$SITE_BACKUP" ]; then

                find "$WEB_ROOT" \
                    -mindepth 1 \
                    -maxdepth 1 \
                    -exec rm -rf -- {} +


                cp -a "$SITE_BACKUP/." "$WEB_ROOT/"

                success "Restored: $SITE_NAME"

            fi

        done < "$DETECTED_FILE"

    fi


    systemctl start "$APACHE_SERVICE"

    exit 1

fi


success "Apache configuration test PASSED."


# ================================================================
# START APACHE
# ================================================================

echo
echo "================================================================"
echo "                    STARTING APACHE"
echo "================================================================"


info "Starting Apache..."


if ! systemctl start "$APACHE_SERVICE"; then

    error "Apache failed to start."


    if [ "$ROLLBACK_ENABLED" = true ]; then

        error "Starting rollback..."


        while IFS='|' read -r SITE_NAME WEB_ROOT
        do

            SAFE_NAME=$(echo "$SITE_NAME" | sed 's/[^a-zA-Z0-9._-]/_/g')

            SITE_BACKUP="$BACKUP_DIR/$SAFE_NAME"


            if [ -d "$SITE_BACKUP" ]; then

                find "$WEB_ROOT" \
                    -mindepth 1 \
                    -maxdepth 1 \
                    -exec rm -rf -- {} +


                cp -a "$SITE_BACKUP/." "$WEB_ROOT/"

                success "Restored: $SITE_NAME"

            fi

        done < "$DETECTED_FILE"


        systemctl start "$APACHE_SERVICE"

    fi


    exit 1

fi


# ================================================================
# WAIT FOR APACHE
# ================================================================

info "Waiting for Apache to stabilize..."

sleep 5


# ================================================================
# FINAL APACHE STATUS
# ================================================================

echo
echo "================================================================"
echo "                    FINAL APACHE STATUS"
echo "================================================================"


if systemctl is-active --quiet "$APACHE_SERVICE"; then

    echo -e "${GREEN}Apache Status : RUNNING${NC}"

else

    echo -e "${RED}Apache Status : FAILED${NC}"

    error "Apache is not running."

    exit 1

fi


# ================================================================
# FINAL WEBSITE REPORT
# ================================================================

echo
echo "================================================================"
echo "                  DEPLOYMENT RESULT"
echo "================================================================"

printf "%-35s %-60s %-12s\n" \
    "SITE" \
    "DOCUMENT ROOT" \
    "STATUS"

echo "----------------------------------------------------------------"


FINAL_FAILURE=false


while IFS='|' read -r SITE_NAME WEB_ROOT
do

    if [ -d "$WEB_ROOT" ] && \
       [ "$(find "$WEB_ROOT" -mindepth 1 -print -quit)" ]; then

        printf "%-35s %-60s ${GREEN}%-12s${NC}\n" \
            "$SITE_NAME" \
            "$WEB_ROOT" \
            "UPDATED"

    else

        printf "%-35s %-60s ${RED}%-12s${NC}\n" \
            "$SITE_NAME" \
            "$WEB_ROOT" \
            "EMPTY"

        FINAL_FAILURE=true

    fi

done < "$DETECTED_FILE"


echo
echo "================================================================"


# ================================================================
# FINAL RESULT
# ================================================================

if [ "$FINAL_FAILURE" = true ]; then

    error "Deployment completed with errors."

    log "DEPLOYMENT FAILED: $DEPLOYMENT_ID"

    exit 1

fi


success "DEPLOYMENT COMPLETED SUCCESSFULLY."

log "DEPLOYMENT SUCCESSFUL: $DEPLOYMENT_ID"


# ================================================================
# BACKUP CLEANUP
# ================================================================

info "Cleaning old backups..."


BACKUP_COUNT=$(find "$BACKUP_BASE" \
    -maxdepth 1 \
    -mindepth 1 \
    -type d \
    -name "deployment_*" \
    | wc -l)


if [ "$BACKUP_COUNT" -gt "$BACKUPS_TO_KEEP" ]; then

    DELETE_COUNT=$((BACKUP_COUNT - BACKUPS_TO_KEEP))


    find "$BACKUP_BASE" \
        -maxdepth 1 \
        -mindepth 1 \
        -type d \
        -name "deployment_*" \
        -printf '%T@ %p\n' \
        | sort -n \
        | head -n "$DELETE_COUNT" \
        | cut -d' ' -f2- \
        | while IFS= read -r OLD_BACKUP
        do

            rm -rf "$OLD_BACKUP"

            info "Removed old backup: $OLD_BACKUP"

        done

fi


# ================================================================
# FINAL SUMMARY
# ================================================================

echo
echo "================================================================"
echo -e "${GREEN}                 DEPLOYMENT SUCCESSFUL${NC}"
echo "================================================================"
echo
echo "Deployment ID : $DEPLOYMENT_ID"
echo "Sites Updated : $SITE_COUNT"
echo "Source        : $SOURCE_DIR"
echo "Backup        : $BACKUP_DIR"
echo "Log           : $LOG_FILE"
echo
echo "Apache Status : RUNNING"
echo
echo "================================================================"
echo


exit 0
