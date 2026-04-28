# jetpack-flash-kit

NVIDIA Jetson Orin NX (ConnectTech Hardron 보드) 에 JetPack 6.2.1을 호스트 PC에서 직접 플래싱하는 스크립트 모음입니다.

## 대상 환경

| 항목 | 값 |
|---|---|
| 타겟 보드 | ConnectTech Hardron (Orin NX) |
| JetPack 버전 | 6.2.1 (L4T R36.4.4) |
| 호스트 OS | Ubuntu 22.04 / 24.04 |
| 플래싱 방식 | NFS (CTI `cti-nvme-flash.sh`) |

## 디렉터리 구조

```
jetpack-flash-kit/
├── flash-host.sh          # 메인 플래싱 스크립트
├── resources/
│   ├── initialize.sh      # chroot 내부 패키지 설치 스크립트
│   ├── Jetson_Linux_R36.4.4_aarch64.tbz2           # NVIDIA BSP (수동 배치 또는 자동 다운로드)
│   ├── Tegra_Linux_Sample-Root-Filesystem_R36.4.4_aarch64.tbz2  # NVIDIA RootFS
│   └── CTI-L4T-ORIN-NX-NANO-36.4.4-V005.tgz       # ConnectTech BSP
└── .env                   # 환경변수 기본값
```

> `l4t-work/` 디렉터리는 플래싱 과정에서 자동 생성됩니다 (`.gitignore` 처리됨).

## 사전 준비

1. **Recovery Mode 연결**: Jetson Orin NX를 Recovery Mode로 진입 후 USB-C 케이블로 호스트 PC에 연결합니다.
2. **리소스 파일 배치**: `resources/` 디렉터리에 BSP, RootFS, CTI BSP 파일을 미리 넣거나, 스크립트 실행 시 자동 다운로드합니다.
3. **root 권한**: 플래싱 시 `sudo` 또는 `root` 셸에서 실행해야 합니다.

## 사용 방법

```bash
# 처음부터 끝까지 전체 실행 (권장)
sudo ./flash-host.sh --all

# 특정 단계부터 재시작
sudo ./flash-host.sh --start 5

# 특정 단계만 실행
sudo ./flash-host.sh --only 4

# 플래싱 전 준비만 수행 (1~6단계)
sudo ./flash-host.sh --prepare-only

# 이미지 플래싱만 실행 (7단계)
sudo ./flash-host.sh --flashing-only

# QSPI 부트로더만 플래싱
sudo ./flash-host.sh --bootloader-only

# 리소스 파일 다운로드만 수행
./flash-host.sh --download-only
```

### 주요 옵션

| 옵션 | 설명 |
|---|---|
| `--all` | 1단계부터 7단계까지 전체 실행 |
| `--start N` | N단계부터 마지막까지 실행 |
| `--only N` | N단계만 단독 실행 |
| `--prepare-only` | 플래싱 전 준비 (1~6단계) |
| `--flashing-only` | NVMe 이미지 플래싱 (7단계) |
| `--bootloader-only` | QSPI 부트로더만 즉시 플래싱 |
| `--download-only` | 리소스 다운로드만 수행 후 종료 |
| `--files-dir PATH` | 리소스 파일 위치 지정 |
| `--work-dir PATH` | 작업 디렉터리 지정 |
| `--board-config NAME` | CTI 보드 설정 이름 지정 |
| `--default-user NAME` | 기본 사용자 이름 |
| `--default-pass PASS` | 기본 사용자 비밀번호 |
| `--default-host NAME` | 기본 호스트 이름 |

### 환경변수

CLI 옵션 대신 환경변수로도 설정할 수 있습니다. CLI 옵션이 환경변수보다 우선합니다.

```bash
export FILES_DIR=/path/to/resources
export BOARD_CONFIG=cti/orin-nx/hadron/base
export DEFAULT_USER=nvidia
export DEFAULT_PASS=nvidia
export DEFAULT_HOST=orinnx
export CTI_VERSION=005
sudo ./flash-host.sh --all
```

`.env` 파일을 소스하여 기본값을 로드할 수도 있습니다:

```bash
source .env && sudo ./flash-host.sh --all
```

## 플래싱 단계

| 단계 | 내용 |
|---|---|
| 1 | 호스트 사전 요구사항 패키지 설치 (QEMU, NFS 등) |
| 2 | NVIDIA L4T BSP 추출 |
| 3 | Root Filesystem 추출 |
| 4 | CTI BSP 적용 및 `apply_binaries.sh` 실행 |
| 5 | chroot 초기화 (CUDA 12.6, ROS2 Humble, Nearthlab 패키지 설치) |
| 6 | 기본 사용자 계정 생성 |
| 7 | NVMe 이미지 플래싱 (NFS 경유) |

### chroot 초기화 상세 (`initialize.sh`)

5단계에서 타겟 rootfs 내부에서 실행됩니다:

- APT 미러를 KAIST(`ftp.kaist.ac.kr/ubuntu-ports`)로 변경
- 시스템 패키지 업데이트
- CUDA 12.6 (`cuda-minimal-build-12-6`) 설치
- ROS2 Humble (`ros-humble-ros-base`) 설치
- Nearthlab 패키지 저장소 등록 및 `nlab-pkg-service-l4t` 설치

## 부트로더 단독 플래싱 (QSPI 복구)

NVMe 플래싱 전 QSPI 부트로더를 별도로 구워야 하는 경우:

```bash
# 1) 부트로더만 플래싱
sudo ./flash-host.sh --bootloader-only

# 2) 디바이스를 Recovery Mode로 재진입 후 NVMe 플래싱
sudo ./flash-host.sh --flashing-only
```

## 트러블슈팅

### Ubuntu 22.04 `sudo` PTY 오류

Ubuntu 22.04의 `Defaults use_pty` sudoers 설정으로 인해 PTY 없는 환경에서 sudo가 실패할 수 있습니다.

```bash
# 방법 1: root 셸에서 실행
sudo -s
./flash-host.sh --all

# 방법 2: sudoers에서 use_pty 제거
sudo visudo   # 'Defaults use_pty' 줄 삭제 또는 주석 처리
```

### 리소스 파일 수동 다운로드

CTI BSP는 ConnectTech 계정이 필요할 수 있습니다. 수동으로 다운로드 후 `resources/`에 배치하세요.

- **NVIDIA BSP**: [NVIDIA L4T R36.4.4](https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.4/release/Jetson_Linux_R36.4.4_aarch64.tbz2)
- **NVIDIA RootFS**: [Tegra RootFS R36.4.4](https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.4/release/Tegra_Linux_Sample-Root-Filesystem_R36.4.4_aarch64.tbz2)
- **CTI BSP**: ConnectTech FTP — `CTI-L4T-ORIN-NX-NANO-36.4.4-V005.tgz`

### 특정 단계 재실행

중간에 오류가 발생한 경우 해당 단계부터 재실행할 수 있습니다:

```bash
sudo ./flash-host.sh --start 4   # CTI BSP 적용부터
sudo ./flash-host.sh --start 5   # chroot 초기화부터
sudo ./flash-host.sh --start 7   # 플래싱만
```
