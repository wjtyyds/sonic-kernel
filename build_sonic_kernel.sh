#!/bin/bash
set -e

TARGET_VER="$1"
if [ -z "$TARGET_VER" ]; then
    echo "❌ 错误: 没找到合法的版本号！"
    exit 1
fi

KERNEL_VER=$(echo "$TARGET_VER" | cut -d'-' -f1)
SIGN_SUFFIX=$(echo "$TARGET_VER" | sed "s/^$KERNEL_VER//")
BASE_VER=$(echo "$KERNEL_VER" | cut -d'.' -f1,2)
WORK_DIR="/workspace/kernel_build"
OUT_DIR="/workspace/output"
MAKE_CMD="make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-"

sudo mkdir -p "$WORK_DIR" "$OUT_DIR"
sudo chown -R $USER:$USER /workspace
cd "$WORK_DIR"

echo "=================================================="
echo " 1. 从 F大 云端提取 .config 配置文件"
echo "=================================================="
URL_STABLE="https://github.com/ophub/kernel/releases/download/kernel_stable/${KERNEL_VER}.tar.gz"
if wget -qO /tmp/env.tar.gz "$URL_STABLE"; then
    tar -xf /tmp/env.tar.gz -C . 2>/dev/null || true
    if [ -d "./${KERNEL_VER}" ]; then
        mv ./${KERNEL_VER}/* . 2>/dev/null || true
    fi
    tar -zxvf boot-*.tar.gz 2>/dev/null || true
    CONFIG_FILE=$(find . -name "config-*" | head -n 1)
    cp "$CONFIG_FILE" .config
    echo "✅ 成功提取配置文件: $CONFIG_FILE"
else
    echo "❌ 找不到 F大 的内核资产包: $KERNEL_VER"
    exit 1
fi

echo "=================================================="
echo " 2. 拉取纯净内核源码并对齐版本"
echo "=================================================="
git clone --depth 1 -b "v${KERNEL_VER}" https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux-src
cd linux-src
cp ../.config .

# 强行对齐内核签名魔数
sed -i 's/CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/g' .config
if grep -q "CONFIG_LOCALVERSION=" .config; then
    sed -i 's/CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="'"$SIGN_SUFFIX"'"/' .config
else
    echo "CONFIG_LOCALVERSION=\"$SIGN_SUFFIX\"" >> .config
fi

echo "=================================================="
echo " 3. 注入 SONiC Fullcone 内核补丁"
echo "=================================================="
git clone --depth 1 https://github.com/mufeng05/openwrt-sonic-fullcone.git /tmp/sonic
# 遍历并应用内核补丁 (适配 nf_nat_core, xt_MASQ, nft_masq)
for patch_file in /tmp/sonic/kernel/*.patch; do
    if [ -f "$patch_file" ]; then
        echo " 正在打入补丁: $(basename "$patch_file")"
        patch -p1 < "$patch_file"
    fi
done

echo "=================================================="
echo " 4. 启动全量内核编译 (这会持续较长时间)"
echo "=================================================="
$MAKE_CMD olddefconfig
$MAKE_CMD -j$(nproc) Image dtbs modules

echo "=================================================="
echo " 5. 按照打包规范构建 Kernel Tarball"
echo "=================================================="
PACK_DIR="$WORK_DIR/pack_out"
mkdir -p "$PACK_DIR/boot" "$PACK_DIR/lib/modules"

# 安装模块
$MAKE_CMD INSTALL_MOD_PATH="$PACK_DIR" modules_install

# 提取核心启动文件
cp arch/arm64/boot/Image "$PACK_DIR/boot/vmlinuz-$TARGET_VER"
cp .config "$PACK_DIR/boot/config-$TARGET_VER"
cp System.map "$PACK_DIR/boot/System.map-$TARGET_VER"

# 清理无效软链接避免打包报错
rm -f "$PACK_DIR/lib/modules/$TARGET_VER/build"
rm -f "$PACK_DIR/lib/modules/$TARGET_VER/source"

cd "$PACK_DIR"
tar -czvf "$OUT_DIR/kernel-sonic-${TARGET_VER}.tar.gz" ./*
echo "✅ 编译打包完成！产物路径: $OUT_DIR/kernel-sonic-${TARGET_VER}.tar.gz"