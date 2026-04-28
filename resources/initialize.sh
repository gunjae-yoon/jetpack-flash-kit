#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

configure_apt_mirror() {
    echo "=== [0/6] APT Mirror + Hook Optimization ==="

    # 어떤 ubuntu-ports 미러든 KAIST로 교체 (mirror.kakao.com은 ubuntu-ports 없음)
    sed -i 's|https\?://[^/]*/ubuntu-ports|http://ftp.kaist.ac.kr/ubuntu-ports|g' \
        /etc/apt/sources.list
    echo "[OK] apt mirror -> http://ftp.kaist.ac.kr/ubuntu-ports"

    # apt 훅 비활성화: QEMU 에뮬레이션 환경에서 apt 실행마다 Python 스크립트
    # (apt-check, appstream, snapd 등)가 호출되어 속도를 크게 저하시킴
    rm -f /etc/apt/apt.conf.d/99update-notifier
    rm -f /etc/apt/apt.conf.d/50appstream
    rm -f /etc/apt/apt.conf.d/20snapd.conf
    rm -f /etc/apt/apt.conf.d/20dbus
    echo "[OK] apt 훅 비활성화 완료"
}

update_system_packages() {
    echo "=== [1/6] System Update ==="
    apt update --allow-insecure-repositories -o Acquire::AllowInsecureRepositories=true 2>/dev/null || true
    apt install -y --allow-unauthenticated gpgv gpg
    apt update
}

install_cuda() {
    echo "=== [2/6] CUDA Installation ==="

    # cuda-toolkit-12-6은 nsight-compute(430MB), *-dev 헤더(~1GB) 등 불필요한 패키지를
    # 모두 포함(총 2.2GB). Jetson 런타임에는 minimal-build로 충분.
    apt install -y cuda-minimal-build-12-6
    if ! grep -q "cuda/bin" /etc/bash.bashrc; then
        cat << 'CUDA_ENV' >> /etc/bash.bashrc

# CUDA
export PATH=/usr/local/cuda/bin:${PATH}
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}
CUDA_ENV
    fi
}

setup_ros2_repository() {
    echo "=== [3/6] ROS2 Humble Repository Setup ==="
    apt install -y curl gnupg lsb-release software-properties-common
    curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
        -o /usr/share/keyrings/ros-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] \
http://packages.ros.org/ros2/ubuntu jammy main" \
        | tee /etc/apt/sources.list.d/ros2.list > /dev/null
    apt update
}

install_ros2_packages() {
    echo "=== [4/6] ROS2 Humble & Tools Installation ==="
    apt install -y ros-humble-ros-base python3-rosdep python3-colcon-common-extensions
    if [ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]; then
        rosdep init
    else
        echo "[INFO] rosdep already initialized, skipping..."
    fi
    rosdep update
    if ! grep -q "ros/humble/setup.bash" /etc/bash.bashrc; then
        echo "source /opt/ros/humble/setup.bash" >> /etc/bash.bashrc
    fi
}

setup_nearthlab_repository() {
    echo "=== [5/6] Nearthlab Repository Setup ==="
    echo "deb [trusted=yes] http://13.209.77.239:8282/pulp/content/deb/nlab default all" \
        | tee /etc/apt/sources.list.d/nlab.list > /dev/null
    apt update
}

install_nearthlab_packages() {
    echo "=== [6/6] Nearthlab Package Management Service Installation ==="
    apt install -y nlab-pkg-service-l4t
}

main() {
    configure_apt_mirror
    update_system_packages
    install_cuda
    setup_ros2_repository
    install_ros2_packages
    setup_nearthlab_repository
    install_nearthlab_packages

    echo ""
    echo "=== Setup Complete ==="
}

main "$@"