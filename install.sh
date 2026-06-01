#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="deb-ombak"
CONFIG_DIR="/etc/${SERVICE_NAME}"
JOBS_DIR="${CONFIG_DIR}/jobs"
LOG_DIR="/var/log/${SERVICE_NAME}"
SCRIPT_DIR="/usr/local/lib/${SERVICE_NAME}"

log()  { echo "[+] $1"; }
info() { echo "[*] $1"; }
err()  { echo "[-] $1" >&2; }

DAYS_OF_WEEK=(mon tue wed thu fri sat sun)

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root: su -; bash install.sh"
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$JOBS_DIR" "$LOG_DIR" "$SCRIPT_DIR"
}

list_uuids() {
  lsblk -f -o UUID,LABEL,FSTYPE,SIZE,MOUNTPOINT,PATH,TYPE 2>/dev/null | \
    grep -v '^UUID' | grep -v '^\s*$' | awk '{print $1}' | grep -v '^\s*$' | sort -u
}

uuid_info() {
  local uuid="$1"
  lsblk -f -o UUID,LABEL,FSTYPE,SIZE,MOUNTPOINT,PATH 2>/dev/null | \
    awk -v u="$uuid" '$1==u {print $0}'
}

get_omv_name() {
  local uuid="$1"
  local config="/etc/openmediavault/config.xml"
  local name=""

  if [[ -f "$config" ]]; then
    name=$(awk -v u="$uuid" '
      BEGIN { found=0; name=""; }
      /<mntent>/ { found=2; }
      found==2 && /<uuid>/ { if (index($0, u)) { found=3; } }
      found==3 && /<dir>/ {
        gsub(/.*<dir>/, ""); gsub(/<\/dir>.*/, "");
        name=$0; found=0;
      }
      END { if (name) print name; }
    ' "$config" 2>/dev/null)

    if [[ -z "$name" ]]; then
      name=$(awk -v u="$uuid" '
        BEGIN { found=0; rname=""; }
        /<raid>/ { found=2; }
        found==2 && /<uuid>/ { if (index($0, u)) { found=3; } }
        found==3 && /<raidname>/ {
          gsub(/.*<raidname>/, ""); gsub(/<\/raidname>.*/, "");
          rname=$0; found=0;
        }
        END { if (rname) print rname; }
      ' "$config" 2>/dev/null)
      [[ -n "$name" ]] && name="RAID: ${name}"
    fi
  fi
  echo "$name"
}

pick_uuid() {
  local title="${1:-Select UUID}"
  local prompt="${2:-Choose a drive:}"
  local items=()
  local uuids=()
  local max_desc_len=60

  while IFS='|' read -r uuid label fstype size mount path; do
    [[ -z "$uuid" || "$uuid" == "UUID" ]] && continue

    local omv_name
    omv_name=$(get_omv_name "$uuid")
    local desc=""

    if [[ -n "$omv_name" ]]; then
      desc="${omv_name}"
    elif [[ -n "$label" && "$label" != "no-label" ]]; then
      desc="${label}"
    else
      desc="${uuid:0:8}..."
    fi

    desc+="  ${fstype:-?}  ${size:-?}"
    [[ -n "$mount" ]] && desc+="  [${mount}]"
    [[ "${#desc}" -gt "$max_desc_len" ]] && desc="${desc:0:$((max_desc_len-3))}..."

    uuids+=("$uuid|$path")
    items+=("$uuid" "$desc")
  done < <(lsblk -f -o UUID,LABEL,FSTYPE,SIZE,MOUNTPOINT,PATH 2>/dev/null | tail -n +2 | \
    sort -k1 | uniq)

  if [[ ${#items[@]} -eq 0 ]]; then
    whiptail --msgbox "No block devices found." 6 30
    return 1
  fi

  local choice
  choice=$(whiptail --menu --title "$title" "$prompt" 20 72 10 \
    "${items[@]}" 3>&1 1>&2 2>&3) || return 1

  echo "$choice"
  return 0
}

mount_uuid() {
  local uuid="$1"
  local mountpoint="/mnt/ombak-${uuid}"
  if mountpoint -q "$mountpoint" 2>/dev/null; then
    echo "$mountpoint"
    return 0
  fi
  mkdir -p "$mountpoint"
  if mount UUID="$uuid" "$mountpoint" 2>/dev/null; then
    echo "$mountpoint"
    return 0
  fi
  rmdir "$mountpoint" 2>/dev/null || true
  return 1
}

umount_uuid() {
  local mountpoint="$1"
  umount "$mountpoint" 2>/dev/null || true
  rmdir "$mountpoint" 2>/dev/null || true
}

format_12h() {
  local h m ampm
  h="${1%%:*}"
  m="${1##*:}"
  if [[ "$h" -eq 0 ]]; then
    ampm="AM"; h=12
  elif [[ "$h" -lt 12 ]]; then
    ampm="AM"
  elif [[ "$h" -eq 12 ]]; then
    ampm="PM"
  else
    ampm="PM"; h=$((h-12))
  fi
  printf "%d:%02d %s" "$h" "$m" "$ampm"
}

job_file() { echo "${JOBS_DIR}/${1}.conf"; }
timer_file() { echo "/etc/systemd/system/${SERVICE_NAME}-${1}.timer"; }
service_file() { echo "/etc/systemd/system/${SERVICE_NAME}-${1}.service"; }
log_file() { echo "${LOG_DIR}/${1}.log"; }

list_jobs() {
  local jobs=()
  for f in "$JOBS_DIR"/*.conf; do
    [[ -f "$f" ]] && jobs+=("$(basename "${f%.conf}")")
  done
  echo "${jobs[@]}"
}

load_job() {
  local name="$1"
  local f
  f=$(job_file "$name")
  JOB_NAME="$name"
  JOB_SRC_UUID=""
  JOB_DST_UUID=""
  JOB_MODE=""          # full or folders
  JOB_FOLDERS=""       # comma-separated
  JOB_SCHEDULE_DAYS=""
  JOB_SCHEDULE_TIME=""
  if [[ -f "$f" ]]; then
    source "$f"
  fi
}

save_job() {
  mkdir -p "$JOBS_DIR"
  local f
  f=$(job_file "$JOB_NAME")
  cat > "$f" <<EOF
JOB_SRC_UUID="${JOB_SRC_UUID}"
JOB_DST_UUID="${JOB_DST_UUID}"
JOB_MODE="${JOB_MODE}"
JOB_FOLDERS="${JOB_FOLDERS}"
JOB_SCHEDULE_DAYS="${JOB_SCHEDULE_DAYS}"
JOB_SCHEDULE_TIME="${JOB_SCHEDULE_TIME}"
EOF
  log "Job '$JOB_NAME' saved"
}

install_backup_script() {
  local name="$1"
  local logf

  logf=$(log_file "$name")

  cat > "${SCRIPT_DIR}/${name}.sh" <<BACKUPSCRIPT
#!/usr/bin/env bash
LOG="${logf}"
CONF="${CONFIG_DIR}/jobs/${name}.conf"

source "\$CONF"

log_msg() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" >> "\$LOG"; }

log_msg "=== Backup job '$name' started ==="
log_msg "Source UUID: \$JOB_SRC_UUID"
log_msg "Dest UUID: \$JOB_DST_UUID"
log_msg "Mode: \$JOB_MODE"

SRC_MPT="/mnt/ombak-src-\${name}"
DST_MPT="/mnt/ombak-dst-\${name}"
mkdir -p "\$SRC_MPT" "\$DST_MPT"

cleanup() {
  umount "\$SRC_MPT" 2>/dev/null || true
  umount "\$DST_MPT" 2>/dev/null || true
  rmdir "\$SRC_MPT" "\$DST_MPT" 2>/dev/null || true
}
trap cleanup EXIT

if ! mount UUID="\$JOB_SRC_UUID" "\$SRC_MPT" 2>/dev/null; then
  log_msg "ERROR: Failed to mount source UUID \$JOB_SRC_UUID"
  exit 1
fi
log_msg "Source mounted at \$SRC_MPT"

if ! mount UUID="\$JOB_DST_UUID" "\$DST_MPT" 2>/dev/null; then
  log_msg "ERROR: Failed to mount dest UUID \$JOB_DST_UUID"
  exit 1
fi
log_msg "Dest mounted at \$DST_MPT"

RSYNC_OPTS="-avh --delete --progress"
DEST_DIR="\${DST_MPT}/ombak-\${name}"

if [[ "\$JOB_MODE" == "full" ]]; then
  log_msg "Backing up entire drive: \$SRC_MPT -> \$DEST_DIR"
  mkdir -p "\$DEST_DIR"
  rsync \$RSYNC_OPTS "\$SRC_MPT/" "\$DEST_DIR/" >> "\$LOG" 2>&1
else
  log_msg "Backing up folders: \$JOB_FOLDERS"
  mkdir -p "\$DEST_DIR"
  IFS=',' read -ra FOLDERS <<< "\$JOB_FOLDERS"
  for folder in "\${FOLDERS[@]}"; do
    folder="\$(echo "\$folder" | xargs)"
    SRC="\${SRC_MPT}/\${folder}"
    DST="\${DEST_DIR}/\${folder}"
    log_msg "Syncing \$SRC -> \$DST"
    mkdir -p "\$(dirname "\$DST")"
    rsync \$RSYNC_OPTS "\$SRC/" "\$DST/" >> "\$LOG" 2>&1
  done
fi

log_msg "=== Backup job '$name' completed ==="
log_msg "Log: \$LOG"
BACKUPSCRIPT
  chmod +x "${SCRIPT_DIR}/${name}.sh"
}

install_systemd_units() {
  local name="$1"

  cat > "$(service_file "$name")" <<EOF
[Unit]
Description=Deb OMBak - Backup Job: ${name}
After=local-fs.target network.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/${name}.sh
User=root
EOF

  cat > "$(timer_file "$name")" <<EOF
[Unit]
Description=Deb OMBak - Backup Timer: ${name}

[Timer]
OnCalendar=daily
Persistent=false

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  log "Systemd units installed for job '$name'"
}

update_timer_time() {
  local name="$1" time="$2"
  local hour minute
  hour="${time%%:*}"
  minute="${time##*:}"
  sed -i "s/^OnCalendar=.*/OnCalendar=*-*-* ${hour}:${minute}:00/" "$(timer_file "$name")"
  systemctl daemon-reload
}

enable_timer() {
  local name="$1"
  systemctl enable --now "${SERVICE_NAME}-${name}.timer" 2>/dev/null || true
}

disable_timer() {
  local name="$1"
  systemctl disable --now "${SERVICE_NAME}-${name}.timer" 2>/dev/null || true
}

show_logs() {
  local log_files=()
  for f in "$LOG_DIR"/*.log; do
    [[ -f "$f" ]] && log_files+=("$f")
  done

  if [[ ${#log_files[@]} -eq 0 ]]; then
    whiptail --msgbox "No logs found in ${LOG_DIR}" 6 45
    return
  fi

  while true; do
    local menu_items=()
    for f in "${log_files[@]}"; do
      local bname
      bname=$(basename "$f")
      local size
      size=$(du -h "$f" 2>/dev/null | cut -f1)
      local lines
      lines=$(wc -l < "$f" 2>/dev/null || echo 0)
      menu_items+=("$bname" "${size}  ${lines} lines")
    done
    menu_items+=("__BACK__" "Return")

    local choice
    choice=$(whiptail --menu --title "Backup Logs — ${LOG_DIR}" \
      "Select a log to view:" 20 65 10 \
      "${menu_items[@]}" \
      3>&1 1>&2 2>&3) || return

    [[ "$choice" == "__BACK__" ]] && return

    local logfile="${LOG_DIR}/${choice}"
    if [[ -f "$logfile" ]]; then
      local content
      content=$(tail -100 "$logfile" 2>/dev/null)
      whiptail --scrolltext --msgbox --title "Log: ${choice}" \
        "${content}" 25 80 2>/dev/null || echo "$content" | less
    fi
  done
}

delete_logs() {
  local log_files=()
  for f in "$LOG_DIR"/*.log; do
    [[ -f "$f" ]] && log_files+=("$f")
  done

  if [[ ${#log_files[@]} -eq 0 ]]; then
    whiptail --msgbox "No logs to delete." 6 30
    return
  fi

  local sel_menu=()
  for f in "${log_files[@]}"; do
    local bname
    bname=$(basename "$f")
    sel_menu+=("$bname" "" OFF)
  done

  local selected
  selected=$(whiptail --checklist --title "Delete Logs" \
    "Select logs to delete:" 20 60 8 \
    "${sel_menu[@]}" 3>&1 1>&2 2>&3) || return

  eval "local to_delete=($selected)" 2>/dev/null || return

  if [[ ${#to_delete[@]} -eq 0 ]]; then
    whiptail --msgbox "No logs selected." 6 30
    return
  fi

  local del_list=""
  for f in "${to_delete[@]}"; do
    del_list+="  ${f}\n"
  done

  if ! whiptail --yesno "Delete these logs?\n${del_list}" 10 55; then
    return
  fi

  for f in "${to_delete[@]}"; do
    rm -f "${LOG_DIR}/${f}"
    log "Deleted log: ${LOG_DIR}/${f}"
  done

  whiptail --msgbox "Deleted ${#to_delete[@]} log file(s)." 6 40
}

create_job() {
  if ! command -v whiptail &>/dev/null; then
    apt-get install -y whiptail 2>/dev/null || { err "whiptail required"; return 1; }
  fi

  ensure_dirs

  local name
  while true; do
    name=$(whiptail --inputbox "Backup job name (no spaces):" 8 50 "" 3>&1 1>&2 2>&3) || return
    [[ -z "$name" ]] && { whiptail --msgbox "Name cannot be empty." 6 30; continue; }
    echo "$name" | grep -qE '^[a-zA-Z0-9_-]+$' || { whiptail --msgbox "Use letters, numbers, -, _ only." 6 45; continue; }
    if [[ -f "$(job_file "$name")" ]]; then
      whiptail --yesno "Job '$name' already exists. Overwrite?" 7 40 || continue
    fi
    JOB_NAME="$name"
    break
  done

  JOB_SRC_UUID=$(pick_uuid "Select Source Drive" "Choose the source drive to back up:") || return
  JOB_DST_UUID=$(pick_uuid "Select Destination Drive" "Choose the destination drive for backups:") || return

  if [[ "$JOB_SRC_UUID" == "$JOB_DST_UUID" ]]; then
    whiptail --msgbox "Source and destination cannot be the same drive." 6 50
    return
  fi

  local mode_choice
  mode_choice=$(whiptail --menu --title "Backup Mode" \
    "What to back up?" 10 50 2 \
    "full"    "Entire drive/partition" \
    "folders" "Select specific folders" \
    3>&1 1>&2 2>&3) || return
  JOB_MODE="$mode_choice"

  if [[ "$JOB_MODE" == "folders" ]]; then
    local src_mpt
    src_mpt=$(mount_uuid "$JOB_SRC_UUID") || {
      whiptail --msgbox "Failed to mount source drive.\nCannot list folders." 7 50
      return
    }
    local folder_items=() folder_names=()
    local idx=0
    while IFS= read -r dir; do
      [[ -z "$dir" ]] && continue
      local dname
      dname=$(basename "$dir")
      folder_names+=("$dname")
      folder_items+=("$dname" "$dir" OFF)
      ((idx++))
    done < <(find "$src_mpt" -maxdepth 1 -type d ! -name 'lost+found' 2>/dev/null | sort)

    umount_uuid "$src_mpt"

    if [[ ${#folder_items[@]} -eq 0 ]]; then
      whiptail --msgbox "No folders found on source drive." 6 40
      return
    fi

    local selected_folders
    selected_folders=$(whiptail --checklist --title "Select Folders to Back Up" \
      "Choose folders (SPACE to toggle, ENTER to confirm):" 20 65 10 \
      "${folder_items[@]}" 3>&1 1>&2 2>&3) || return

    eval "local folder_arr=($selected_folders)" 2>/dev/null
    if [[ ${#folder_arr[@]} -eq 0 ]]; then
      whiptail --msgbox "No folders selected." 6 30
      return
    fi

    JOB_FOLDERS=""
    for f in "${folder_arr[@]}"; do
      [[ -n "$JOB_FOLDERS" ]] && JOB_FOLDERS+=","
      JOB_FOLDERS+="$f"
    done
  else
    JOB_FOLDERS=""
  fi

  local selected days_arr day
  selected=$(whiptail --checklist --title "Backup Schedule" \
    "Select backup days (\xE2\x86\x91\xE2\x86\x93 arrows, SPACE toggle, ENTER confirm):" \
    16 55 7 \
    "mon" "Monday"    OFF \
    "tue" "Tuesday"   OFF \
    "wed" "Wednesday" OFF \
    "thu" "Thursday"  OFF \
    "fri" "Friday"    OFF \
    "sat" "Saturday"  OFF \
    "sun" "Sunday"    OFF \
    3>&1 1>&2 2>&3) || return

  eval "days_arr=($selected)" 2>/dev/null
  if [[ ${#days_arr[@]} -eq 0 ]]; then
    whiptail --msgbox "No days selected. Job will not be scheduled." 7 45
    JOB_SCHEDULE_DAYS=""
    JOB_SCHEDULE_TIME=""
  else
    JOB_SCHEDULE_DAYS=""
    for day in "${days_arr[@]}"; do
      [[ -n "$JOB_SCHEDULE_DAYS" ]] && JOB_SCHEDULE_DAYS+=","
      JOB_SCHEDULE_DAYS+="$day"
    done

    JOB_SCHEDULE_TIME=$(whiptail --inputbox --title "Backup Time" \
      "Enter backup time (24h HH:MM)\nExample: 02:00 = 2:00 AM" \
      10 55 "02:00" 3>&1 1>&2 2>&3) || return

    if [[ ! "$JOB_SCHEDULE_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
      whiptail --msgbox --title "Invalid Time" \
        "Use HH:MM in 24h format." 7 35
      return
    fi
  fi

  local summary="Job: ${JOB_NAME}\n"
  summary+="Source: ${JOB_SRC_UUID}\n"
  summary+="Dest:   ${JOB_DST_UUID}\n"
  summary+="Mode:   ${JOB_MODE}\n"
  if [[ "$JOB_MODE" == "folders" && -n "$JOB_FOLDERS" ]]; then
    summary+="Folders:\n"
    IFS=',' read -ra farr <<< "$JOB_FOLDERS"
    for f in "${farr[@]}"; do summary+="  - ${f}\n"; done
  fi
  if [[ -n "$JOB_SCHEDULE_DAYS" ]]; then
    summary+="Schedule: ${JOB_SCHEDULE_DAYS} at ${JOB_SCHEDULE_TIME}"
  else
    summary+="Schedule: manual only (no timer)"
  fi

  if ! whiptail --yesno "Create this backup job?\n\n${summary}" 18 65; then
    return
  fi

  save_job
  install_backup_script "$JOB_NAME"

  if [[ -n "$JOB_SCHEDULE_DAYS" && -n "$JOB_SCHEDULE_TIME" ]]; then
    install_systemd_units "$JOB_NAME"
    update_timer_time "$JOB_NAME" "$JOB_SCHEDULE_TIME"
    enable_timer "$JOB_NAME"
  fi

  whiptail --msgbox "Backup job '$JOB_NAME' created.\nLogs: ${LOG_DIR}/${JOB_NAME}.log" 7 55
}

run_job_now() {
  local jobs
  jobs=($(list_jobs))
  if [[ ${#jobs[@]} -eq 0 ]]; then
    whiptail --msgbox "No backup jobs configured." 6 35
    return
  fi

  local menu_items=()
  for j in "${jobs[@]}"; do
    local info=""
    load_job "$j"
    if systemctl is-active --quiet "${SERVICE_NAME}-${j}.timer" 2>/dev/null; then
      info="scheduled"
    else
      info="manual only"
    fi
    menu_items+=("$j" "$info")
  done

  local choice
  choice=$(whiptail --menu --title "Run Backup Now" \
    "Select a job to run immediately:" 15 60 6 \
    "${menu_items[@]}" \
    3>&1 1>&2 2>&3) || return

  if whiptail --yesno "Run backup job '$choice' now?\n\nThis may take a while." 8 50; then
    log "Running job '$choice' manually"
    whiptail --msgbox "Running backup in background.\nCheck logs: ${LOG_DIR}/${choice}.log" 7 55
    "${SCRIPT_DIR}/${choice}.sh" &
  fi
}

manage_jobs() {
  while true; do
    local jobs
    jobs=($(list_jobs))
    local menu_items=()
    local job_names=()

    if [[ ${#jobs[@]} -eq 0 ]]; then
      whiptail --msgbox "No backup jobs configured." 6 35
      return
    fi

    for j in "${jobs[@]}"; do
      load_job "$j"
      local timer_status
      timer_status=$(systemctl is-active "${SERVICE_NAME}-${j}.timer" 2>/dev/null || echo "inactive")
      local desc="Timer: ${timer_status}"
      [[ "$JOB_MODE" == "full" ]] && desc+=" | full drive"
      [[ "$JOB_MODE" == "folders" ]] && desc+=" | folders"
      menu_items+=("$j" "$desc")
      job_names+=("$j")
    done
    menu_items+=("__BACK__" "Return to main menu")

    local choice
    choice=$(whiptail --menu --title "Manage Backup Jobs" \
      "Select a job to manage:" 20 60 8 \
      "${menu_items[@]}" \
      3>&1 1>&2 2>&3) || return

    [[ "$choice" == "__BACK__" ]] && return

    local c2
    c2=$(whiptail --menu --title "Job: $choice" \
      "What to do with '$choice'?" 12 50 4 \
      "RUN"    "Run backup now" \
      "REMOVE" "Delete job and timer" \
      "BACK"   "Return" \
      3>&1 1>&2 2>&3) || continue

    case "$c2" in
      RUN)
        if whiptail --yesno "Run backup job '$choice' now?" 7 40; then
          log "Running job '$choice' from manage menu"
          "${SCRIPT_DIR}/${choice}.sh" &
          whiptail --msgbox "Backup started in background.\nCheck logs: ${LOG_DIR}/${choice}.log" 7 60
        fi
        ;;
      REMOVE)
        if whiptail --yesno "Remove job '$choice'?\n\nThis deletes config, systemd units, and backup script.\nLogs will be kept." 10 55; then
          disable_timer "$choice"
          rm -f "$(timer_file "$choice")" "$(service_file "$choice")" "$(job_file "$choice")" "${SCRIPT_DIR}/${choice}.sh"
          systemctl daemon-reload
          log "Job '$choice' removed"
          whiptail --msgbox "Job '$choice' removed." 6 35
        fi
        ;;
      BACK) continue ;;
    esac
  done
}

show_main_menu() {
  local choice
  local jobs
  jobs=($(list_jobs))
  local timer_count=0
  for j in "${jobs[@]}"; do
    systemctl is-active --quiet "${SERVICE_NAME}-${j}.timer" 2>/dev/null && ((timer_count++))
  done

  choice=$(whiptail --menu --title "Deb OMBak — OMV Backup" \
    "OpenMediaVault backup utility\nJobs: ${#jobs[@]} | Active timers: ${timer_count}" \
    16 60 7 \
    "1" "Create a backup job" \
    "2" "Run backup now" \
    "3" "Manage backup jobs" \
    "4" "View backup logs" \
    "5" "Delete logs" \
    "6" "Exit" \
    3>&1 1>&2 2>&3) || return 1

  case "$choice" in
    1) create_job ;;
    2) run_job_now ;;
    3) manage_jobs ;;
    4) show_logs ;;
    5) delete_logs ;;
    6) return 1 ;;
  esac
  return 0
}

check_deps() {
  local missing=()
  command -v whiptail &>/dev/null || missing+=("whiptail")
  command -v rsync &>/dev/null || missing+=("rsync")
  command -v lsblk &>/dev/null || missing+=("util-linux")
  if [[ ${#missing[@]} -gt 0 ]]; then
    if whiptail --yesno "Missing dependencies: ${missing[*]}\nInstall now?" 8 50; then
      apt-get update -qq && apt-get install -y "${missing[@]}"
    else
      err "Missing: ${missing[*]}"
      exit 1
    fi
  fi
}

main() {
  require_root
  check_deps
  ensure_dirs

  while true; do
    show_main_menu || break
  done

  log "Goodbye."
}

main
