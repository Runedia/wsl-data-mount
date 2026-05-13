#!/usr/bin/env bash
# WSL2 자동 마운트 시스템 부트스트랩 — Ubuntu(WSL) 측 일괄 설정.
#
# PC 초기화 후 또는 다른 머신에서 동일 구성을 재현할 때 한 번 실행한다.
# 라벨(기본 wsldata)로 디바이스를 자동 탐지하므로 sdX 번호가 바뀌어도 동작한다.
#
# 사용:
#   sudo bash Setup-Ubuntu-DataMount.sh                  # 기본값으로 진행
#   sudo bash Setup-Ubuntu-DataMount.sh --label mydata --mount-point /mnt/llm
#   sudo bash Setup-Ubuntu-DataMount.sh --force-format   # 라벨 매칭 디바이스 없을 때 신규 ext4 포맷
#   sudo bash Setup-Ubuntu-DataMount.sh --dry-run        # 변경 없이 계획만 출력
#
# 전제 조건:
#   - Windows측 Setup-WSL-DataMount.ps1로 디스크가 이미 부착된 상태
#   - 본 distro에 sudo 가능한 사용자가 존재

set -euo pipefail

LABEL='wsldata'
MOUNT_POINT='/mnt/data'
OWNER=''
DEFAULT_USER=''
FORCE_FORMAT='false'
DRY_RUN='false'
ASSUME_YES='false'

usage() {
    cat <<EOF
Setup-Ubuntu-DataMount.sh — WSL Ubuntu 측 데이터 디스크 자동 마운트 설정

옵션:
  --label LABEL          ext4 파티션 라벨 (기본: wsldata)
  --mount-point PATH     마운트 지점 (기본: /mnt/data)
  --owner USER           마운트 지점 소유자 (기본: \$SUDO_USER)
  --default-user USER    /etc/wsl.conf의 default user (기본: 현재 SUDO_USER)
  --force-format         라벨 매칭 디바이스가 없을 때 가장 큰 미사용 디스크를 ext4로 포맷
  --dry-run              실제 변경 없이 계획만 출력
  --yes                  대화형 확인 생략
  -h, --help             본 도움말
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --label)         LABEL="$2"; shift 2 ;;
        --mount-point)   MOUNT_POINT="$2"; shift 2 ;;
        --owner)         OWNER="$2"; shift 2 ;;
        --default-user)  DEFAULT_USER="$2"; shift 2 ;;
        --force-format)  FORCE_FORMAT='true'; shift ;;
        --dry-run)       DRY_RUN='true'; shift ;;
        --yes)           ASSUME_YES='true'; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "[ERROR] 알 수 없는 옵션: $1" >&2; usage; exit 1 ;;
    esac
done

# --- 색상 출력 ---
if [[ -t 1 ]]; then
    C_INFO='\033[36m'; C_OK='\033[32m'; C_WARN='\033[33m'; C_ERR='\033[31m'; C_RST='\033[0m'
else
    C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_RST=''
fi
log_info() { printf "${C_INFO}[INFO]${C_RST}  %s\n" "$*"; }
log_ok()   { printf "${C_OK}[OK]${C_RST}    %s\n" "$*"; }
log_warn() { printf "${C_WARN}[WARN]${C_RST}  %s\n" "$*"; }
log_err()  { printf "${C_ERR}[ERROR]${C_RST} %s\n" "$*" >&2; }

run_cmd() {
    if [[ "$DRY_RUN" == 'true' ]]; then
        printf "  [DRY] %s\n" "$*"
    else
        eval "$@"
    fi
}

# --- 권한 확인 ---
if [[ "$EUID" -ne 0 ]]; then
    log_err "본 스크립트는 sudo로 실행해야 합니다."
    exit 1
fi

CALLER="${SUDO_USER:-}"
if [[ -z "$CALLER" ]]; then
    log_warn 'SUDO_USER 미설정. 비-sudo 환경에서 직접 root로 실행 중인 것으로 간주.'
    CALLER='root'
fi
[[ -z "$OWNER" ]] && OWNER="$CALLER"
[[ -z "$DEFAULT_USER" ]] && DEFAULT_USER="$CALLER"
log_info "호출자=$CALLER, 마운트 소유자=$OWNER, distro default user=$DEFAULT_USER"
[[ "$DRY_RUN" == 'true' ]] && log_warn 'DRY-RUN 모드 — 실제 변경 없음'

# --- 디바이스 탐색 ---
log_info '--- 디바이스 탐색 ---'

# lsblk -P로 안전한 파싱
find_device_by_label() {
    local lbl="$1"
    # 파티션 우선 (sdXN), 없으면 디스크 자체
    lsblk -P -o NAME,FSTYPE,LABEL,UUID,SIZE,TYPE 2>/dev/null | while IFS= read -r line; do
        local name fstype label uuid size type
        eval "$line"
        if [[ "$LABEL" == "$lbl" && "$FSTYPE" == 'ext4' ]]; then
            echo "/dev/${NAME}|${UUID}|${SIZE}|${TYPE}"
        fi
    done
}

CANDIDATES="$(find_device_by_label "$LABEL")"
DEVICE=''
UUID=''

if [[ -n "$CANDIDATES" ]]; then
    count=$(echo "$CANDIDATES" | wc -l)
    if [[ "$count" -gt 1 ]]; then
        log_err "라벨 '$LABEL' 매칭 디바이스가 $count 개. 수동 확인 필요:"
        echo "$CANDIDATES"
        exit 1
    fi
    IFS='|' read -r DEVICE UUID SIZE TYPE <<< "$CANDIDATES"
    log_ok "라벨 매칭: device=$DEVICE  UUID=$UUID  Size=$SIZE  Type=$TYPE"
elif [[ "$FORCE_FORMAT" == 'true' ]]; then
    log_warn "라벨 '$LABEL' 매칭 디바이스 없음. --force-format으로 신규 포맷 진행."
    # 후보: 미파티션 + 가장 큰 디스크
    log_info '디스크 후보 (FSTYPE/LABEL 없는 것):'
    CANDS=$(lsblk -d -P -o NAME,SIZE,MODEL,FSTYPE | awk -F'"' '
        /TYPE/ {next}
        { name=$2; size=$4; model=$6; fstype=$8;
          if (fstype == "" && name !~ /^loop/) print name "|" size "|" model }
    ')
    if [[ -z "$CANDS" ]]; then
        # MODEL 컬럼이 없을 수 있어 안전 fallback
        CANDS=$(lsblk -d -P -o NAME,SIZE,FSTYPE | awk -F'"' '{ name=$2; size=$4; fstype=$6;
            if (fstype == "" && name !~ /^loop/) print name "|" size "|" }')
    fi
    if [[ -z "$CANDS" ]]; then
        log_err '포맷 가능한 후보 디스크가 없습니다. Windows측에서 디스크가 부착되었는지 확인하십시오.'
        exit 1
    fi
    echo "$CANDS" | nl
    if [[ "$ASSUME_YES" != 'true' ]]; then
        read -r -p '위 후보 중 포맷할 디스크 NAME (예: sdd): ' PICK
    else
        PICK=$(echo "$CANDS" | head -1 | cut -d'|' -f1)
        log_warn "--yes 모드: 자동 선택 $PICK"
    fi
    [[ -z "$PICK" ]] && { log_err '선택 없음. 중단.'; exit 1; }
    DEV="/dev/$PICK"
    [[ -b "$DEV" ]] || { log_err "디바이스 $DEV 없음"; exit 1; }

    log_warn "DESTRUCTIVE: $DEV 를 GPT + ext4($LABEL) 로 포맷합니다."
    if [[ "$ASSUME_YES" != 'true' ]]; then
        read -r -p "정말 진행하시려면 디바이스명을 다시 입력하십시오 ($PICK): " CONFIRM
        [[ "$CONFIRM" == "$PICK" ]] || { log_err '확인 실패. 중단.'; exit 1; }
    fi
    run_cmd "wipefs -a $DEV"
    run_cmd "parted $DEV --script mklabel gpt"
    run_cmd "parted -a optimal $DEV --script mkpart primary ext4 0% 100%"
    run_cmd "mkfs.ext4 -L $LABEL -F ${DEV}1"
    if [[ "$DRY_RUN" != 'true' ]]; then
        DEVICE="${DEV}1"
        UUID=$(blkid -s UUID -o value "$DEVICE")
    else
        DEVICE="${DEV}1"
        UUID="<dry-run-uuid>"
    fi
    log_ok "포맷 완료: device=$DEVICE  UUID=$UUID"
else
    log_err "라벨 '$LABEL' 매칭 디바이스 없음."
    log_info '현재 상태:'
    lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT
    echo
    log_info '조치 옵션:'
    log_info '  1) Windows측 Setup-WSL-DataMount.ps1로 디스크 부착이 완료되었는지 확인'
    log_info "  2) 기존 ext4 라벨이 다르면 --label <기존라벨> 로 재시도"
    log_info "  3) 신규 디스크면 --force-format 옵션 추가"
    exit 1
fi

# --- /etc/wsl.conf 보강 (idempotent) ---
log_info '--- /etc/wsl.conf 보강 ---'
WSLCONF=/etc/wsl.conf
[[ -f "$WSLCONF" ]] || { run_cmd "touch $WSLCONF"; }

# 항목별 idempotent 보강: python 없이 awk로 [section]/key 처리
ensure_kv_in_section() {
    local section="$1" key="$2" value="$3" file="$4"
    if [[ "$DRY_RUN" == 'true' ]]; then
        printf "  [DRY] ensure [%s] %s = %s in %s\n" "$section" "$key" "$value" "$file"
        return
    fi
    awk -v sect="[$section]" -v k="$key" -v v="$value" '
        BEGIN { in_sect=0; printed=0; have_sect=0 }
        /^\[.*\]$/ {
            if (in_sect && !printed) { print k " = " v; printed=1 }
            in_sect = ($0 == sect)
            if (in_sect) have_sect=1
            print; next
        }
        in_sect && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
            if (!printed) { print k " = " v; printed=1 }
            next
        }
        { print }
        END {
            if (!have_sect) {
                print ""
                print sect
                print k " = " v
            } else if (in_sect && !printed) {
                print k " = " v
            }
        }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

ensure_kv_in_section 'boot' 'systemd' 'true' "$WSLCONF"
ensure_kv_in_section 'user' 'default' "$DEFAULT_USER" "$WSLCONF"
ensure_kv_in_section 'interop' 'enabled' 'true' "$WSLCONF"
ensure_kv_in_section 'interop' 'appendWindowsPath' 'true' "$WSLCONF"
log_ok '/etc/wsl.conf 보강 완료'
log_info "현재 내용:"
sed -e 's/^/    /' "$WSLCONF"

# --- /etc/fstab 등록 ---
log_info '--- /etc/fstab 등록 ---'
FSTAB=/etc/fstab
TS=$(date +%Y%m%d%H%M%S)
if [[ -f "$FSTAB" ]]; then
    run_cmd "cp -a $FSTAB ${FSTAB}.bak-$TS"
    log_info "백업: ${FSTAB}.bak-$TS"
fi

# 같은 mount-point에 매핑된 기존 라인이 있으면 제거
if grep -qE "[[:space:]]${MOUNT_POINT}[[:space:]]" "$FSTAB" 2>/dev/null; then
    log_warn "기존 $MOUNT_POINT 라인 존재. 새 라인으로 교체."
    if [[ "$DRY_RUN" != 'true' ]]; then
        grep -vE "[[:space:]]${MOUNT_POINT}[[:space:]]" "$FSTAB" > "${FSTAB}.tmp"
        mv "${FSTAB}.tmp" "$FSTAB"
    fi
fi

NEW_LINE="UUID=${UUID}  ${MOUNT_POINT}  ext4  defaults,nofail,x-systemd.device-timeout=10s  0  2"
if [[ "$DRY_RUN" == 'true' ]]; then
    printf "  [DRY] append to %s:\n    %s\n" "$FSTAB" "$NEW_LINE"
else
    printf '%s\n' "$NEW_LINE" >> "$FSTAB"
fi
log_ok "fstab 라인 추가: $NEW_LINE"

# --- 마운트 지점 생성 + chown ---
log_info '--- 마운트 지점 준비 ---'
run_cmd "mkdir -p $MOUNT_POINT"
if id -u "$OWNER" >/dev/null 2>&1; then
    run_cmd "chown ${OWNER}:${OWNER} $MOUNT_POINT"
    log_ok "소유권: ${OWNER}:${OWNER} → $MOUNT_POINT"
else
    log_warn "사용자 '$OWNER' 미존재. chown 스킵."
fi

# --- mount -a 검증 ---
log_info '--- mount -a 검증 ---'
if [[ "$DRY_RUN" != 'true' ]]; then
    if mountpoint -q "$MOUNT_POINT"; then
        log_info "$MOUNT_POINT 이미 마운트됨. umount 후 fstab로 재마운트 시도."
        umount "$MOUNT_POINT" 2>/dev/null || log_warn 'umount 실패 (busy일 수 있음). 계속 진행.'
    fi
    if mount -a; then
        log_ok 'mount -a 성공'
    else
        log_warn 'mount -a 비0 종료. nofail 옵션으로 부팅에는 영향 없음. 디바이스가 곧 인식될 수 있음.'
    fi
    if mountpoint -q "$MOUNT_POINT"; then
        log_ok "최종: $(df -hT "$MOUNT_POINT" | tail -1)"
    else
        log_warn "$MOUNT_POINT 미마운트 상태. 다음 wsl --shutdown 후 재시작 시 처리됩니다."
    fi
fi

# --- 종합 보고 ---
echo
log_ok '=== Ubuntu측 설정 완료 ==='
echo "  디바이스       : $DEVICE"
echo "  UUID           : $UUID"
echo "  마운트 지점    : $MOUNT_POINT"
echo "  소유자         : $OWNER"
echo "  /etc/wsl.conf  : 갱신됨"
echo "  /etc/fstab     : 갱신됨 (백업: ${FSTAB}.bak-$TS)"
echo
echo "검증:"
echo "  df -hT $MOUNT_POINT"
echo "  ls -ld $MOUNT_POINT"
