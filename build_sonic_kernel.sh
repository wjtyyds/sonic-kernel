#!/bin/bash

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
TARGET_VER=""

# 1. 参数解析 (兼容你的 OAF 脚本逻辑)
for arg in "$@"; do
    if echo "$arg" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+-'; then
        TARGET_VER="$arg"
        break
    fi
done

if [ -z "$TARGET_VER" ]; then
    echo "❌ 错误: 没找到合法的版本号！"
    exit 1
fi

VERSION_NAME=$(echo "$TARGET_VER" | sed 's/^k//')
KERNEL_VER=$(echo "$VERSION_NAME" | cut -d'-' -f1)
SIGN_SUFFIX=$(echo "$VERSION_NAME" | sed "s/^$KERNEL_VER//")
AUTHOR=$(echo "$VERSION_NAME" | cut -d'-' -f2)
BASE_VER=$(echo "$KERNEL_VER" | cut -d'.' -f1,2)

WORK_DIR="/workspace/kernel/$AUTHOR/$KERNEL_VER"
OUT_DIR="/workspace/build_sonic/output/$VERSION_NAME"
DEVICE_TYPE="${DEVICE_TYPE:-amlogic}"

if [ "$DEVICE_TYPE" == "rk35xx" ]; then
    REPO_NAME="linux-${BASE_VER}.y-rockchip"
else
    REPO_NAME="linux-${BASE_VER}.y"
fi
LINUX_DIR="$WORK_DIR/$REPO_NAME"

if [ "$COMPILER_TYPE" = "clang" ]; then
    MAKE_CMD="make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld LLVM=1 LLVM_IAS=1"
else
    MAKE_CMD="make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-"
fi

mkdir -p "$WORK_DIR"
sudo mkdir -p "/workspace/build_sonic/output"
cd "$WORK_DIR"

# 2. 从 F大 (wjtyyds) 提取 boot 与 .config 环境
echo " 正在从 wjtyyds 检查并提取 Header 与 Boot 环境..."
if ! ls boot-*.tar.gz 1> /dev/null 2>&1; then
    if [ "$DEVICE_TYPE" == "rk35xx" ]; then
        URL_RK="https://github.com/ophub/kernel/releases/download/kernel_rk35xx/${KERNEL_VER}.tar.gz"
        if sudo wget -qO /tmp/env.tar.gz "$URL_RK"; then
            sudo tar -xf /tmp/env.tar.gz -C . 2>/dev/null || true
            sudo rm -f /tmp/env.tar.gz
        fi
    else
        URL_FLIPPY="https://github.com/wjtyyds/amlogic-s9xxx-armbian/releases/download/kernel_flippy/${KERNEL_VER}.tar"
        URL_STABLE="https://github.com/wjtyyds/amlogic-s9xxx-armbian/releases/download/kernel_stable/${KERNEL_VER}.tar.gz"
        URL_OPHUB="https://github.com/ophub/kernel/releases/download/kernel_stable/${KERNEL_VER}.tar.gz"
        
        if sudo wget -qO /tmp/env.tar "$URL_FLIPPY"; then
            echo "✅ 从 kernel_flippy 下载成功"
            sudo tar -xf /tmp/env.tar -C . 2>/dev/null || true
            sudo rm -f /tmp/env.tar
        elif sudo wget -qO /tmp/env.tar.gz "$URL_STABLE"; then
            echo "✅ 从 kernel_stable 下载成功"
            sudo tar -xf /tmp/env.tar.gz -C . 2>/dev/null || true
            sudo rm -f /tmp/env.tar.gz
        elif sudo wget -qO /tmp/env.tar.gz "$URL_OPHUB"; then
            echo "✅ 从 ophub/kernel 下载成功"
            sudo tar -xf /tmp/env.tar.gz -C . 2>/dev/null || true
            sudo rm -f /tmp/env.tar.gz
        fi
    fi
fi

if [ ! -d "boot_env" ]; then
    sudo mkdir -p boot_env
    sudo tar -zxvf boot-*.tar.gz -C boot_env 2>/dev/null || true
fi

# 获取 .config 路径
HEADER_DIR=$(realpath $(dirname $(sudo find boot_env -name "config-*" | head -n 1)))

# 3. 源码拉取 (沿用原有的 unifreq 与 kernel.org 兜底逻辑)
echo "=================================================="
if [ ! -d "$LINUX_DIR/.git" ]; then
    echo " 未发现本地源码，开始拉取源码树..."
    sudo rm -rf "$LINUX_DIR"
    mkdir "$LINUX_DIR"
    cd "$LINUX_DIR"
    sudo git init

    if git ls-remote "https://github.com/unifreq/${REPO_NAME}.git" &>/dev/null; then
        echo "✅ 找到定制分支！正在从 unifreq 拉取..."
        sudo git remote add origin "https://github.com/unifreq/${REPO_NAME}.git"
        COMMIT_HASH=$(sudo git ls-remote origin | grep -E "refs/tags/v${KERNEL_VER}(\^\{\})?$" | tail -n 1 | awk '{print $1}')
        
        if [ -n "$COMMIT_HASH" ]; then
            sudo git fetch --depth 1 origin $COMMIT_HASH
            sudo git checkout FETCH_HEAD
        else
            echo "⚠️ 未找到 Tag，回退至 kernel.org..."
            sudo git remote set-url origin "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git" 2>/dev/null || sudo git remote add origin "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
            sudo git fetch --depth 1 origin "tags/v${KERNEL_VER}"
            sudo git checkout FETCH_HEAD
        fi
    else
        echo "⚠️ unifreq 不存在，回退至 kernel.org..."
        sudo git remote add origin "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
        sudo git fetch --depth 1 origin "tags/v${KERNEL_VER}"
        sudo git checkout FETCH_HEAD
    fi
    cd ..
fi

cd "$LINUX_DIR"

# 注入 .config 和版本号后缀
sudo cp $HEADER_DIR/.config .
sudo sed -i 's/CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/g' .config
if grep -q "CONFIG_LOCALVERSION=" .config; then
    sudo sed -i 's/CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="'"$SIGN_SUFFIX"'"/' .config
else
    echo "CONFIG_LOCALVERSION=\"$SIGN_SUFFIX\"" | sudo tee -a .config > /dev/null
fi

SYS_VER_1=$(echo $KERNEL_VER | cut -d. -f1)
SYS_VER_2=$(echo $KERNEL_VER | cut -d. -f2)
SYS_VER_3=$(echo $KERNEL_VER | cut -d. -f3)
sudo sed -i "s/^VERSION = .*/VERSION = $SYS_VER_1/" Makefile
sudo sed -i "s/^PATCHLEVEL = .*/PATCHLEVEL = $SYS_VER_2/" Makefile
sudo sed -i "s/^SUBLEVEL = .*/SUBLEVEL = $SYS_VER_3/" Makefile
sudo sed -i "s/^EXTRAVERSION = .*/EXTRAVERSION = /" Makefile

# 4. 注入 SONiC 内核补丁
echo "=================================================="
echo " 正在注入 SONiC Fullcone 补丁..."
sudo git clone --depth 1 https://github.com/mufeng05/openwrt-sonic-fullcone.git /tmp/sonic
for patch_file in /tmp/sonic/kernel/*.patch; do
    if [ -f "$patch_file" ]; then
        echo " -> 应用补丁: $(basename "$patch_file")"
        sudo patch -p1 < "$patch_file"
    fi
done

# 5. 全量编译
echo "=================================================="
echo "🚀 启动全量内核编译 (Image, dtbs, modules)..."
sudo $MAKE_CMD olddefconfig
sudo $MAKE_CMD clean
sudo $MAKE_CMD -j$(nproc) Image dtbs modules

# 6. 打包输出
echo "=================================================="
PACK_DIR="$WORK_DIR/pack_out"
sudo mkdir -p "$PACK_DIR/boot" "$PACK_DIR/lib/modules"

sudo $MAKE_CMD INSTALL_MOD_PATH="$PACK_DIR" modules_install
sudo cp arch/arm64/boot/Image "$PACK_DIR/boot/vmlinuz-$VERSION_NAME"
sudo cp .config "$PACK_DIR/boot/config-$VERSION_NAME"
sudo cp System.map "$PACK_DIR/boot/System.map-$VERSION_NAME"

sudo rm -f "$PACK_DIR/lib/modules/$VERSION_NAME/build"
sudo rm -f "$PACK_DIR/lib/modules/$VERSION_NAME/source"

cd "$PACK_DIR"
sudo mkdir -p "$OUT_DIR"
sudo tar -czvf "$OUT_DIR/kernel-sonic-${VERSION_NAME}.tar.gz" ./*
echo "✅ 编译打包完成！产物位于: $OUT_DIR/kernel-sonic-${VERSION_NAME}.tar.gz"
