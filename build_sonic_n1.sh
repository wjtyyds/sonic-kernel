#!/bin/bash
set -e

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
TARGET_VER="$1"

if [ -z "$TARGET_VER" ]; then
    echo "❌ 错误: 没找到合法的版本号！"
    exit 1
fi

# 解析版本号和后缀
VERSION_NAME=$(echo "$TARGET_VER" | sed 's/^k//')
KERNEL_VER=$(echo "$VERSION_NAME" | cut -d'-' -f1)
# === 在这里强行截胡，覆盖为你自定义的后缀 ===
SIGN_SUFFIX="-wjtyyds"
VERSION_NAME="${KERNEL_VER}${SIGN_SUFFIX}"
AUTHOR="wjtyyds"
BASE_VER=$(echo "$KERNEL_VER" | cut -d'.' -f1,2)
# ============================================
SIGN_SUFFIX=$(echo "$VERSION_NAME" | sed "s/^$KERNEL_VER//")
AUTHOR=$(echo "$VERSION_NAME" | cut -d'-' -f2)
BASE_VER=$(echo "$KERNEL_VER" | cut -d'.' -f1,2)

WORK_DIR="/workspace/kernel/$AUTHOR/$KERNEL_VER"
OUT_DIR="/workspace/build_sonic/output/$VERSION_NAME"
FINAL_TAR_DIR="/workspace/build_sonic/final_release"
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

sudo mkdir -p "$WORK_DIR" "$OUT_DIR" "$FINAL_TAR_DIR"
sudo chown -R $USER:$USER /workspace   # 添加这一行，把权限还给当前用户
cd "$WORK_DIR"

echo "=================================================="
echo " 1. 正在从 wjtyyds (F大) 提取 Header 与 Boot 环境..."
echo "=================================================="
if ! ls boot-*.tar.gz 1> /dev/null 2>&1; then
    if [ "$DEVICE_TYPE" == "rk35xx" ]; then
        URL_RK="https://github.com/ophub/kernel/releases/download/kernel_rk35xx/${KERNEL_VER}.tar.gz"
        if sudo wget -qO /tmp/env.tar.gz "$URL_RK"; then
            sudo tar -xf /tmp/env.tar.gz -C . 2>/dev/null || true
        fi
    else
        URL_FLIPPY="https://github.com/wjtyyds/amlogic-s9xxx-armbian/releases/download/kernel_flippy/${KERNEL_VER}.tar"
        URL_STABLE="https://github.com/wjtyyds/amlogic-s9xxx-armbian/releases/download/kernel_stable/${KERNEL_VER}.tar.gz"
        URL_OPHUB="https://github.com/ophub/kernel/releases/download/kernel_stable/${KERNEL_VER}.tar.gz"
        
        if sudo wget -qO /tmp/env.tar "$URL_FLIPPY"; then
            echo "✅ 从 kernel_flippy 下载成功"
            sudo tar -xf /tmp/env.tar -C . 2>/dev/null || true
        elif sudo wget -qO /tmp/env.tar.gz "$URL_STABLE"; then
            echo "✅ 从 kernel_stable 下载成功"
            sudo tar -xf /tmp/env.tar.gz -C . 2>/dev/null || true
        elif sudo wget -qO /tmp/env.tar.gz "$URL_OPHUB"; then
            echo "✅ 从 ophub/kernel 下载成功"
            sudo tar -xf /tmp/env.tar.gz -C . 2>/dev/null || true
        fi
    fi
fi

if [ ! -d "boot_env" ]; then
    sudo mkdir -p boot_env
    sudo tar -zxvf boot-*.tar.gz -C boot_env 2>/dev/null || true
fi

# 核心修复：找到 config-xxx 文件，并重命名提取到工作目录的安全位置
CONFIG_FILE=$(sudo find boot_env -name "config-*" | head -n 1)
if [ -f "$CONFIG_FILE" ]; then
    sudo cp "$CONFIG_FILE" "$WORK_DIR/.config_base"
    echo "✅ 已成功提取内核配置文件: $CONFIG_FILE"
else
    echo "❌ 提取失败：在 boot_env 中找不到 config 文件！"
    exit 1
fi

echo "=================================================="
echo " 2. 拉取纯净源码并对齐 unifreq 定制分支..."
echo "=================================================="
if [ ! -d "$LINUX_DIR/.git" ]; then
    sudo rm -rf "$LINUX_DIR"
    mkdir "$LINUX_DIR"
    cd "$LINUX_DIR"
    sudo git init

    if git ls-remote "https://github.com/unifreq/${REPO_NAME}.git" &>/dev/null; then
        echo "✅ 正在从 unifreq 专属分支拉取..."
        sudo git remote add origin "https://github.com/unifreq/${REPO_NAME}.git"
        COMMIT_HASH=$(sudo git ls-remote origin | grep -E "refs/tags/v${KERNEL_VER}(\^\{\})?$" | tail -n 1 | awk '{print $1}')
        
        if [ -n "$COMMIT_HASH" ]; then
            sudo git fetch --depth 1 origin $COMMIT_HASH
            sudo git checkout FETCH_HEAD
        else
            echo "⚠️ 未找到对应 Tag，回退至 kernel.org..."
            sudo git remote set-url origin "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git" 2>/dev/null || sudo git remote add origin "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
            sudo git fetch --depth 1 origin "tags/v${KERNEL_VER}"
            sudo git checkout FETCH_HEAD
        fi
    else
        echo "⚠️ unifreq 不存在此仓库，回退至 kernel.org..."
        sudo git remote add origin "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
        sudo git fetch --depth 1 origin "tags/v${KERNEL_VER}"
        sudo git checkout FETCH_HEAD
    fi
    cd ..
fi

cd "$LINUX_DIR"

echo "=================================================="
echo " 3. 注入地基配置与修改内核魔数..."
echo "=================================================="
# 将上一步备好的基础配置文件注入为当前内核的 .config
sudo cp "$WORK_DIR/.config_base" ./.config
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

echo "=================================================="
echo " 4. 引入 SONiC Fullcone 深度内核补丁..."
echo "=================================================="
sudo git clone --depth 1 https://github.com/mufeng05/openwrt-sonic-fullcone.git /tmp/sonic
for patch_file in /tmp/sonic/kernel/*.patch; do
    if [ -f "$patch_file" ]; then
        echo " -> 正在植入: $(basename "$patch_file")"
        sudo patch -p1 < "$patch_file"
    fi
done

echo "=================================================="
echo " 5. 启动全系统内核编译 (Image, dtbs, modules)..."
echo "=================================================="
sudo $MAKE_CMD olddefconfig
sudo $MAKE_CMD clean
sudo $MAKE_CMD KBUILD_MODPOST_WARN=1 KCFLAGS="-Wno-error" HOSTCFLAGS="-Wno-error" -j$(nproc) Image dtbs modules

echo "=================================================="
echo " 6. 按 F大 规范执行分体打包 (boot / modules / dtb / header)"
echo "=================================================="
PACK_DIR="$WORK_DIR/pack_out"
sudo mkdir -p "$PACK_DIR"

# 6.1 打包 boot
echo " -> 正在打包 boot 组件..."
sudo mkdir -p "$PACK_DIR/boot_tmp/boot"
sudo cp arch/arm64/boot/Image "$PACK_DIR/boot_tmp/boot/vmlinuz-$VERSION_NAME"
sudo cp .config "$PACK_DIR/boot_tmp/boot/config-$VERSION_NAME"
sudo cp System.map "$PACK_DIR/boot_tmp/boot/System.map-$VERSION_NAME"
(cd "$PACK_DIR/boot_tmp" && sudo tar -czf "$OUT_DIR/boot-${VERSION_NAME}.tar.gz" .)

# 6.2 打包 modules
echo " -> 正在打包 modules 组件..."
sudo mkdir -p "$PACK_DIR/modules_tmp"
sudo $MAKE_CMD INSTALL_MOD_PATH="$PACK_DIR/modules_tmp" modules_install
sudo rm -f "$PACK_DIR/modules_tmp/lib/modules/$VERSION_NAME/build"
sudo rm -f "$PACK_DIR/modules_tmp/lib/modules/$VERSION_NAME/source"
(cd "$PACK_DIR/modules_tmp" && sudo tar -czf "$OUT_DIR/modules-${VERSION_NAME}.tar.gz" .)

# 6.3 打包 dtb-amlogic
echo " -> 正在打包 dtb-amlogic 组件..."
sudo mkdir -p "$PACK_DIR/dtb_tmp/boot/dtb-amlogic"
sudo cp arch/arm64/boot/dts/amlogic/*.dtb "$PACK_DIR/dtb_tmp/boot/dtb-amlogic/" 2>/dev/null || true
(cd "$PACK_DIR/dtb_tmp" && sudo tar -czf "$OUT_DIR/dtb-amlogic-${VERSION_NAME}.tar.gz" .)

# 6.4 提取并补齐 header
echo " -> 正在同步 header 组件..."
if [ -f "$WORK_DIR/header-${VERSION_NAME}.tar.gz" ]; then
    sudo cp "$WORK_DIR/header-${VERSION_NAME}.tar.gz" "$OUT_DIR/"
elif ls $WORK_DIR/header-*.tar.gz 1> /dev/null 2>&1; then
    sudo cp $WORK_DIR/header-*.tar.gz "$OUT_DIR/header-${VERSION_NAME}.tar.gz"
fi

echo "=================================================="
echo " 7. 汇总打包为一个标准 .tar 压缩包"
echo "=================================================="
cd "$OUT_DIR"
sudo tar -cf "${FINAL_TAR_DIR}/${VERSION_NAME}.tar" *.tar.gz

echo "✅ SONiC 全量内核终极打包完毕: ${FINAL_TAR_DIR}/${VERSION_NAME}.tar"
