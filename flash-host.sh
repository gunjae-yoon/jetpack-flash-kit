#!/bin/bash
# flash-host.sh
# Ubuntu 22.04 / 24.04 호스트에서 직접 Jetson Orin NX (Hardron)에 JetPack 6.2.1을 플래싱합니다.
#
# 사전 조건:
#   - Jetson Orin NX를 Recovery Mode로 USB 연결
#   - resources/ 디렉터리에 BSP, rootfs, CTI BSP 파일 배치
#
# 환경변수:
#   FILES_DIR        플래싱 파일 위치     (기본값: <스크립트>/resources)
#   WORK_DIR         작업(추출) 디렉터리  (기본값: <스크립트>/l4t-work)
#   BOARD_CONFIG     CTI 보드 설정        (기본값: cti/orin-nx/hadron/base)
#   CTI_VERSION      CTI BSP 버전         (기본값: 005)
#   BSP_URL          NVIDIA BSP 다운로드 URL
#   ROOTFS_URL       NVIDIA RootFS 다운로드 URL
#   CTI_URL          CTI BSP 다운로드 URL
#   DEFAULT_USER     기본 사용자 이름     (기본값: nvidia)
#   DEFAULT_PASS     기본 사용자 비밀번호 (기본값: nvidia)
#   DEFAULT_HOST     기본 호스트 이름     (기본값: orinnx)
#   START_STEP       시작 단계 번호 (기본값: 1)
#   ONLY_STEP        해당 단계만 실행 (기본값: 비활성)
#   BOOTLOADER_ONLY  1이면 QSPI 부트로더만 플래싱 (기본값: 0)
#
# 단계:
#   1  사전 요구사항 패키지 설치
#   2  L4T BSP 추출
#   3  Root Filesystem 추출
#   4  CTI BSP 적용 + apply_binaries.sh
#   5  chroot 초기화 (미러 설정, CUDA, ROS2, nlab 패키지 설치)
#   6  기본 사용자 계정 생성 (nvidia/nvidia)
#   7  이미지 플래싱
#
# 사용 예:
#   ./flash-host.sh                    # 도움말 출력
#   START_STEP=5 ./flash-host.sh       # chroot 초기화부터 재실행
#   START_STEP=7 ./flash-host.sh       # 플래싱만 재실행
#   ONLY_STEP=4 ./flash-host.sh        # CTI BSP 적용 step만 실행
#   BOOTLOADER_ONLY=1 ./flash-host.sh   # QSPI 부트로더만
#   ./flash-host.sh --download-only     # 리소스 다운로드만 수행
#   ./flash-host.sh --all              # 처음부터 끝까지
#   ./flash-host.sh --start 1          # 처음부터 끝까지
#   ./flash-host.sh --start 5
#   ./flash-host.sh --only 4
#   ./flash-host.sh --prepare-only     # 플래싱 전 단계(1~6)만
#   ./flash-host.sh --flashing-only    # 이미지 플래싱만
#   ./flash-host.sh --bootloader-only  # 부트로더만 바로 플래싱

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIGINAL_ARGS=("$@")

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --files-dir PATH        플래싱 파일 위치
  --work-dir PATH         작업(추출) 디렉터리
  --board-config NAME     CTI 보드 설정
  --default-user NAME     기본 사용자 이름
  --default-pass PASS     기본 사용자 비밀번호
  --default-host NAME     기본 호스트 이름
  --all                   1단계부터 끝까지 실행
  --start N               N 단계부터 끝까지 실행 (1~7)
  --only N                N 단계만 실행 (1~7)
  --prepare-only          플래싱 전 단계(1~6)만 실행
  --flashing-only         이미지 플래싱만 실행 (7단계)
  --bootloader-only       QSPI 부트로더만 즉시 플래싱 (step 1~6 건너뜀)
  --download-only         리소스 다운로드만 수행 후 종료
  --help                  도움말 출력

Environment variables are also supported and used as defaults.
CLI options override environment variables.
EOF
}

FILES_DIR="${FILES_DIR:-$SCRIPT_DIR/resources}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/l4t-work}"
BOARD_CONFIG="${BOARD_CONFIG:-cti/orin-nx/hadron/base}"
CTI_VERSION="${CTI_VERSION:-005}"
BSP_FILE_NAME="Jetson_Linux_R36.4.4_aarch64.tbz2"
ROOTFS_FILE_NAME="Tegra_Linux_Sample-Root-Filesystem_R36.4.4_aarch64.tbz2"
CTI_FILE_NAME="CTI-L4T-ORIN-NX-NANO-36.4.4-V${CTI_VERSION}.tgz"
BSP_URL="${BSP_URL:-https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.4/release/Jetson_Linux_R36.4.4_aarch64.tbz2}"
ROOTFS_URL="${ROOTFS_URL:-https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.4/release/Tegra_Linux_Sample-Root-Filesystem_R36.4.4_aarch64.tbz2}"
CTI_URL="${CTI_URL:-https://connecttech.com/ftp/Drivers/$CTI_FILE_NAME}"
DEFAULT_USER="${DEFAULT_USER:-nvidia}"
DEFAULT_PASS="${DEFAULT_PASS:-nvidia}"
DEFAULT_HOST="${DEFAULT_HOST:-orinnx}"
START_STEP="${START_STEP:-1}"
END_STEP="${END_STEP:-7}"
ONLY_STEP="${ONLY_STEP:-}"
BOOTLOADER_ONLY="${BOOTLOADER_ONLY:-0}"
DOWNLOAD_ONLY="${DOWNLOAD_ONLY:-0}"
INIT_SCRIPT_NAME="initialize.sh"

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --files-dir)
                if [ -z "${2:-}" ] || [[ "${2:-}" == --* ]]; then
                    echo "[ERROR] --files-dir 인자에 값이 필요합니다."
                    echo ""
                    usage
                    exit 1
                fi
                FILES_DIR="$2"
                shift 2
                ;;
            --work-dir)
                if [ -z "${2:-}" ] || [[ "${2:-}" == --* ]]; then
                    echo "[ERROR] --work-dir 인자에 값이 필요합니다."
                    echo ""
                    usage
                    exit 1
                fi
                WORK_DIR="$2"
                shift 2
                ;;
            --board-config)
                if [ -z "${2:-}" ] || [[ "${2:-}" == --* ]]; then
                    echo "[ERROR] --board-config 인자에 값이 필요합니다."
                    echo ""
                    usage
                    exit 1
                fi
                BOARD_CONFIG="$2"
                shift 2
                ;;
            --default-user)
                if [ -z "${2:-}" ] || [[ "${2:-}" == --* ]]; then
                    echo "[ERROR] --default-user 인자에 값이 필요합니다."
                    echo ""
                    usage
                    exit 1
                fi
                DEFAULT_USER="$2"
                shift 2
                ;;
            --default-pass)
                if [ -z "${2:-}" ] || [[ "${2:-}" == --* ]]; then
                    echo "[ERROR] --default-pass 인자에 값이 필요합니다."
                    echo ""
                    usage
                    exit 1
                fi
                DEFAULT_PASS="$2"
                shift 2
                ;;
            --default-host)
                if [ -z "${2:-}" ] || [[ "${2:-}" == --* ]]; then
                    echo "[ERROR] --default-host 인자에 값이 필요합니다."
                    echo ""
                    usage
                    exit 1
                fi
                DEFAULT_HOST="$2"
                shift 2
                ;;
            --all)
                START_STEP=1
                END_STEP=7
                ONLY_STEP=""
                shift
                ;;
            --start)
                if [ -z "${2:-}" ] || [[ "${2:-}" == --* ]]; then
                    echo "[ERROR] --start 인자에 값이 필요합니다."
                    echo ""
                    usage
                    exit 1
                fi
                START_STEP="$2"
                shift 2
                ;;
            --only)
                if [ -z "${2:-}" ] || [[ "${2:-}" == --* ]]; then
                    echo "[ERROR] --only 인자에 값이 필요합니다."
                    echo ""
                    usage
                    exit 1
                fi
                ONLY_STEP="$2"
                shift 2
                ;;
            --prepare-only)
                START_STEP=1
                END_STEP=6
                ONLY_STEP=""
                BOOTLOADER_ONLY=0
                shift
                ;;
            --flashing-only)
                ONLY_STEP=7
                END_STEP=7
                BOOTLOADER_ONLY=0
                shift
                ;;
            --bootloader-only)
                BOOTLOADER_ONLY=1
                shift
                ;;
            --download-only)
                DOWNLOAD_ONLY=1
                BOOTLOADER_ONLY=0
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "[ERROR] 알 수 없는 인자: $1"
                echo ""
                usage
                exit 1
                ;;
        esac
    done
}

if [ "$#" -eq 0 ]; then
    usage
    exit 0
fi

parse_args "$@"

# ── root 권한 확인 ────────────────────────────────────────────────────────────
# Ubuntu 22.04: sudoers "Defaults use_pty"로 인해 PTY 없는 환경에서 sudo가 전부 실패.
# 가장 확실한 해결책은 처음부터 root로 실행하는 것.
# root면 SUDO 변수를 비워서 sudo 없이 직접 실행, 일반 유저면 sudo 사용.
if [ "$DOWNLOAD_ONLY" = "1" ]; then
    SUDO=""
elif [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    # sudo가 동작하는지 확인
    if ! sudo -n true 2>/dev/null && \
       sudo true 2>&1 | grep -qi "allocate pty\|pseudo"; then
        echo "[ERROR] sudo PTY 할당 실패 (Ubuntu 22.04 'Defaults use_pty' 문제)"
        echo ""
        echo "  해결 방법 (택 1):"
        echo "  1) root로 재실행:  sudo -s  →  $(printf '%q ' "$0") $(printf '%q ' "${ORIGINAL_ARGS[@]}")"
        echo "  2) sudoers 수정:   sudo visudo  →  'Defaults use_pty' 줄 삭제 또는 주석 처리"
        exit 1
    fi
    SUDO="sudo"
fi

# ── Ubuntu 버전 확인 ──────────────────────────────────────────────────────────
HOST_OS_ID=$(grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
HOST_OS_VER=$(grep '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')

if [ "$DOWNLOAD_ONLY" = "0" ] && { [ "$HOST_OS_ID" != "ubuntu" ] || { [ "$HOST_OS_VER" != "22.04" ] && [ "$HOST_OS_VER" != "24.04" ]; }; }; then
    echo "[WARN] 미검증 호스트 OS: $HOST_OS_ID $HOST_OS_VER (Ubuntu 22.04 / 24.04 권장)"
    echo "       계속하려면 Enter, 중단하려면 Ctrl+C"
    read -r
fi

L4T_DIR="$WORK_DIR/Linux_for_Tegra"
ROOTFS_DIR="$L4T_DIR/rootfs"
INIT_SCRIPT_PATH="$FILES_DIR/$INIT_SCRIPT_NAME"

# ── 헬퍼 ─────────────────────────────────────────────────────────────────────

validate_step_number() {
    case "$1" in
        1|2|3|4|5|6|7) ;;
        *)
            echo "[ERROR] step 번호는 1~7 범위여야 합니다: $1"
            exit 1
            ;;
    esac
}

validate_bool_flag() {
    case "$1" in
        0|1) ;;
        *)
            echo "[ERROR] BOOTLOADER_ONLY 값은 0 또는 1 이어야 합니다: $1"
            exit 1
            ;;
    esac
}

download_file_if_missing() {
    local target_path="$1"
    local download_url="$2"
    local label="$3"
    local tmp_path="${target_path}.part"

    if [ -f "$target_path" ]; then
        echo "[SKIP] ${label} 이미 존재: $(basename "$target_path")"
        return 0
    fi

    if [ -z "$download_url" ]; then
        echo "[ERROR] ${label} 다운로드 URL이 비어 있습니다."
        echo "        환경변수 설정 후 재실행하세요: export CTI_URL='<다운로드 URL>'"
        exit 1
    fi

    echo "[INFO] ${label} 다운로드 중..."
    echo "       URL: $download_url"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-delay 3 -o "$tmp_path" "$download_url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$tmp_path" "$download_url"
    else
        echo "[ERROR] curl 또는 wget이 필요합니다."
        exit 1
    fi

    mv "$tmp_path" "$target_path"
    echo "[OK] 다운로드 완료: $(basename "$target_path")"
}

prepare_resource_archives() {
    mkdir -p "$FILES_DIR"

    BSP_FILE="$FILES_DIR/$BSP_FILE_NAME"
    ROOTFS_FILE="$FILES_DIR/$ROOTFS_FILE_NAME"
    CTI_FILE="$FILES_DIR/$CTI_FILE_NAME"

    echo "=== 리소스 준비(다운로드) ==="
    download_file_if_missing "$BSP_FILE" "$BSP_URL" "NVIDIA BSP"
    download_file_if_missing "$ROOTFS_FILE" "$ROOTFS_URL" "NVIDIA RootFS"
    download_file_if_missing "$CTI_FILE" "$CTI_URL" "CTI BSP"
    echo ""
}

# ONLY_STEP이 지정되면 해당 step만, 아니면 START_STEP부터 끝까지 실행
run_step() {
    local step="$1"

    if [ -n "$ONLY_STEP" ]; then
        [ "$step" -eq "$ONLY_STEP" ]
    else
        [ "$step" -ge "$START_STEP" ] && [ "$step" -le "$END_STEP" ]
    fi
}

requires_resource_archives() {
    run_step 2 || run_step 3 || run_step 4
}

requires_initialize_script() {
    run_step 5
}

validate_step_number "$START_STEP"
validate_step_number "$END_STEP"
if [ -n "$ONLY_STEP" ]; then
    validate_step_number "$ONLY_STEP"
fi
validate_bool_flag "$BOOTLOADER_ONLY"
validate_bool_flag "$DOWNLOAD_ONLY"
if [ "$START_STEP" -gt "$END_STEP" ]; then
    echo "[ERROR] START_STEP이 END_STEP보다 클 수 없습니다: $START_STEP > $END_STEP"
    exit 1
fi
if [ "$BOOTLOADER_ONLY" = "1" ] && [ -n "$ONLY_STEP" ]; then
    echo "[ERROR] --bootloader-only(또는 BOOTLOADER_ONLY=1)와 --only는 함께 사용할 수 없습니다."
    exit 1
fi
if [ "$DOWNLOAD_ONLY" = "1" ] && [ "$BOOTLOADER_ONLY" = "1" ]; then
    echo "[ERROR] --download-only와 --bootloader-only는 함께 사용할 수 없습니다."
    exit 1
fi

if [ "$DOWNLOAD_ONLY" = "1" ]; then
    echo "=== 리소스 다운로드 전용 모드 ==="
    echo "  FILES_DIR      : $FILES_DIR"
    echo "  CTI_VERSION    : $CTI_VERSION"
    echo ""
    prepare_resource_archives
    echo "=== 다운로드 완료 ==="
    exit 0
fi

cleanup_chroot_mounts() {
    $SUDO umount "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
    $SUDO umount "$ROOTFS_DIR/dev"     2>/dev/null || true
    $SUDO umount "$ROOTFS_DIR/proc"    2>/dev/null || true
    $SUDO umount "$ROOTFS_DIR/sys"     2>/dev/null || true
}

run_bootloader_flash() {
    if [ ! -x "$L4T_DIR/flash.sh" ]; then
        echo "[ERROR] flash.sh를 찾을 수 없습니다: $L4T_DIR/flash.sh"
        echo "        Linux_for_Tegra 준비가 필요합니다. 예: ./flash-host.sh --all"
        exit 1
    fi

    if [ ! -f "$L4T_DIR/$BOARD_CONFIG.conf" ] && [ ! -f "$L4T_DIR/$BOARD_CONFIG" ]; then
        echo "[ERROR] BOARD_CONFIG 파일을 찾을 수 없습니다: $BOARD_CONFIG"
        echo "        먼저 CTI 설정 적용을 완료하세요. 예: ./flash-host.sh --only 4"
        exit 1
    fi

    echo "=== 부트로더 전용 플래싱 (QSPI) ==="
    echo "  방법: flash.sh + NO_ROOTFS=1 (blank QSPI 대응)"
    echo ""
    cd "$L4T_DIR"
    $SUDO NO_ROOTFS=1 ./flash.sh "$BOARD_CONFIG" mmcblk0p1
    echo ""
    echo "=== 부트로더 플래싱 완료 ==="
    echo "  다음: 디바이스를 Recovery Mode로 재진입 후 ./flash-host.sh --start 7"
}

run_image_flash() {
    local nfs_images="$L4T_DIR/tools/kernel_flash/images"
    local nfs_perm="rw,nohide,insecure,no_subtree_check,async,no_root_squash"

    $SUDO mkdir -p "$nfs_images"
    $SUDO chmod 755 "$nfs_images" "$ROOTFS_DIR"
    $SUDO chown root:root "$nfs_images" "$ROOTFS_DIR"

    $SUDO sed -i '/^# Pre-added for NFS flash/,+2d' /etc/exports
    { echo "# Pre-added for NFS flash"
      echo "$ROOTFS_DIR *($nfs_perm)"
      echo "$nfs_images *($nfs_perm)"; } | $SUDO tee -a /etc/exports > /dev/null

    $SUDO exportfs -ra
    $SUDO systemctl restart nfs-kernel-server 2>/dev/null || \
        $SUDO service nfs-kernel-server restart
    showmount -e localhost 2>/dev/null || true

    echo "=== [7/7] 이미지 플래싱 시작 ==="
    echo "  BOARD_CONFIG: $BOARD_CONFIG"
    echo ""
    cd "$L4T_DIR"
    $SUDO CTI-L4T/cti-nvme-flash.sh "$BOARD_CONFIG"
    echo ""
    echo "=== 이미지 플래싱 완료 ==="
}

# ── 시작 배너 ─────────────────────────────────────────────────────────────────

echo "=== JetPack 6.2.1 Host Flash ==="
echo "  HOST OS        : Ubuntu $HOST_OS_VER"
echo "  FILES_DIR      : $FILES_DIR"
echo "  WORK_DIR       : $WORK_DIR"
echo "  BOARD_CONFIG   : $BOARD_CONFIG"
echo "  USER / HOST    : $DEFAULT_USER / $DEFAULT_HOST"
echo "  START_STEP     : $START_STEP"
if [ -z "$ONLY_STEP" ] && [ "$END_STEP" -ne 7 ]; then
    echo "  END_STEP       : $END_STEP"
fi
if [ -n "$ONLY_STEP" ]; then
    echo "  ONLY_STEP      : $ONLY_STEP"
fi
echo "  BOOTLOADER_ONLY: $BOOTLOADER_ONLY"
if requires_initialize_script; then
    echo "  INIT_SCRIPT    : $INIT_SCRIPT_PATH"
fi
echo ""

# --bootloader-only는 단계 실행을 건너뛰고 즉시 부트로더 플래싱만 수행
if [ "$BOOTLOADER_ONLY" = "1" ]; then
    run_bootloader_flash
    exit 0
fi

# ── 파일 확인 (단계 2 이상에서 필요) ─────────────────────────────────────────
if requires_resource_archives; then
    prepare_resource_archives

    for var_name in BSP_FILE ROOTFS_FILE CTI_FILE; do
        val="${!var_name}"
        if [ ! -f "$val" ]; then
            echo "[ERROR] $var_name 파일을 찾을 수 없습니다: $val"
            exit 1
        fi
        echo "[OK] $(basename "$val")"
    done
    echo ""
fi

if requires_initialize_script; then
    if [ ! -f "$INIT_SCRIPT_PATH" ]; then
        echo "[ERROR] initialize 스크립트를 찾을 수 없습니다: $INIT_SCRIPT_PATH"
        exit 1
    fi
    echo "[OK] $(basename "$INIT_SCRIPT_PATH")"
    echo ""
fi

mkdir -p "$WORK_DIR"

# ── STEP 1: 사전 요구사항 ────────────────────────────────────────────────────
if run_step 1; then
    echo "=== [1/7] 사전 요구사항 확인 ==="

    REQUIRED_PKGS=(
        qemu-user-static binfmt-support
        gdisk parted fdisk
        lz4 zstd bzip2 xz-utils cpio abootimg xxd binutils
        bc cpp libxml2-utils python3-yaml uuid-runtime
        sshpass openssh-client rsync iproute2 iputils-ping
        nfs-kernel-server device-tree-compiler
    )

    MISSING=()
    for pkg in "${REQUIRED_PKGS[@]}"; do
        dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
    done

    if [ "${#MISSING[@]}" -gt 0 ]; then
        echo "[INFO] 설치 중: ${MISSING[*]}"
        $SUDO apt-get update -qq
        $SUDO apt-get install -y "${MISSING[@]}"
    else
        echo "[OK] 모든 패키지 설치됨"
    fi

    if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        echo "[INFO] QEMU aarch64 binfmt 등록 중..."
        if [ "$HOST_OS_VER" = "22.04" ]; then
            $SUDO update-binfmts --enable qemu-aarch64 2>/dev/null || \
                $SUDO systemctl restart binfmt-support
        else
            # Ubuntu 24.04: systemd-binfmt이 POF 플래그로 등록
            $SUDO systemctl restart systemd-binfmt 2>/dev/null || \
                $SUDO update-binfmts --enable qemu-aarch64 2>/dev/null || \
                $SUDO systemctl restart binfmt-support
        fi
    fi
    BINFMT_FLAGS=$(cat /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null | grep '^flags:' || echo "flags: unknown")
    echo "[OK] QEMU aarch64 binfmt 활성 ($BINFMT_FLAGS)"
    echo ""
fi

# ── STEP 2: L4T BSP 추출 ─────────────────────────────────────────────────────
if run_step 2; then
    echo "=== [2/7] L4T BSP 추출 ==="
    if [ ! -d "$L4T_DIR" ]; then
        echo "[INFO] 추출 중... (수 분 소요)"
        tar xf "$BSP_FILE" -C "$WORK_DIR"
        echo "[OK] 완료: $L4T_DIR"
    else
        echo "[SKIP] Linux_for_Tegra 이미 존재"
    fi
    echo ""
fi

# ── STEP 3: Root Filesystem 추출 ─────────────────────────────────────────────
if run_step 3; then
    echo "=== [3/7] Root Filesystem 추출 ==="
    if [ ! -f "$ROOTFS_DIR/bin/bash" ]; then
        echo "[INFO] 추출 중 (sudo 필요, 수 분 소요)..."
        $SUDO tar xpf "$ROOTFS_FILE" -C "$ROOTFS_DIR/"
        echo "[OK] 완료: $ROOTFS_DIR"
    else
        echo "[SKIP] rootfs 이미 존재"
    fi
    echo ""
fi

# ── STEP 4: CTI BSP 적용 + apply_binaries.sh ─────────────────────────────────
if run_step 4; then
    echo "=== [4/7] CTI BSP 적용 ==="

    if [ ! -d "$L4T_DIR/CTI-L4T" ]; then
        echo "[INFO] CTI BSP 추출 중..."
        tar xf "$CTI_FILE" -C "$L4T_DIR/"
    else
        echo "[SKIP] CTI-L4T 이미 존재"
    fi

    echo "[INFO] CTI install.sh 실행 중..."
    cd "$L4T_DIR/CTI-L4T"
    $SUDO bash ./install.sh

    echo "[INFO] apply_binaries.sh 실행 중..."
    cd "$L4T_DIR"
    $SUDO ./apply_binaries.sh

    echo "[OK] 완료"
    echo ""
fi

# ── STEP 5: chroot 초기화 ────────────────────────────────────────────────────
if run_step 5; then
    echo "=== [5/7] chroot 초기화 ==="

    trap cleanup_chroot_mounts EXIT

    $SUDO cp /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/"
    $SUDO cp /etc/resolv.conf             "$ROOTFS_DIR/etc/resolv.conf"

    $SUDO mount --bind /dev     "$ROOTFS_DIR/dev"
    $SUDO mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"
    $SUDO mount -t proc  proc   "$ROOTFS_DIR/proc"
    $SUDO mount -t sysfs sysfs  "$ROOTFS_DIR/sys"

    $SUDO cp "$INIT_SCRIPT_PATH" "$ROOTFS_DIR/tmp/init.sh"
    $SUDO chmod +x "$ROOTFS_DIR/tmp/init.sh"

    $SUDO chroot "$ROOTFS_DIR" /tmp/init.sh || {
        echo "[WARN] chroot 초기화 일부 오류 발생. 계속 진행합니다."
    }

    $SUDO rm -f "$ROOTFS_DIR/tmp/init.sh"
    $SUDO rm -f "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"
    cleanup_chroot_mounts
    trap - EXIT
    echo "[OK] 완료"
    echo ""
fi

# ── STEP 6: 기본 사용자 계정 생성 ────────────────────────────────────────────
if run_step 6; then
    echo "=== [6/7] 기본 사용자 계정 생성 ==="
    cd "$L4T_DIR"
    $SUDO tools/l4t_create_default_user.sh \
        -u "$DEFAULT_USER" \
        -p "$DEFAULT_PASS" \
        -n "$DEFAULT_HOST" \
        --accept-license
    echo "[OK] 사용자 생성: $DEFAULT_USER / $DEFAULT_PASS (호스트: $DEFAULT_HOST)"
    echo ""
fi

# ── STEP 7: 이미지 플래싱 ───────────────────────────────────────────────────
if run_step 7; then
    run_image_flash
fi
