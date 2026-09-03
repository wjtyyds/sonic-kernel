#!/bin/bash

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
TARGET_VER=""

for arg in "$@"; do
    if echo "$arg" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+-'; then
        TARGET_VER="$arg"
        break
    fi
done

if [ -z "$TARGET_VER" ]; then
    echo "❌ 错误: 没找到合法的版本号！请确认是否输入了类似 k6.12.103-flippy-95+o 的参数。"
    exit 1
fi

VERSION_NAME=$(echo "$TARGET_VER" | sed 's/^k//')

echo "=================================================="
echo " 捕捉到输入参数: $TARGET_VER"
echo "✅ 实际解析版本: $VERSION_NAME"
echo "=================================================="

if [ "$COMPILER_TYPE" = "clang" ]; then
    echo "⚡ 正在以 LLVM/Clang 核心执行编译..."
    MAKE_CMD="make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld LLVM=1 LLVM_IAS=1"
else
    echo "🔧 正在以 GCC 核心执行编译..."
    MAKE_CMD="make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-"
fi

KERNEL_VER=$(echo "$VERSION_NAME" | cut -d'-' -f1)
SIGN_SUFFIX=$(echo "$VERSION_NAME" | sed "s/^$KERNEL_VER//")
AUTHOR=$(echo "$VERSION_NAME" | cut -d'-' -f2)
BASE_VER=$(echo "$KERNEL_VER" | cut -d'.' -f1,2)

WORK_DIR="/workspace/kernel/$AUTHOR/$KERNEL_VER"
OUT_DIR="/workspace/build_fullcone/output/$VERSION_NAME"
DEVICE_TYPE="${DEVICE_TYPE:-amlogic}"

if [ "$DEVICE_TYPE" == "rk35xx" ]; then
    REPO_NAME="linux-${BASE_VER}.y-rockchip"
else
    REPO_NAME="linux-${BASE_VER}.y"
fi
LINUX_DIR="$WORK_DIR/$REPO_NAME"

mkdir -p "$WORK_DIR"
sudo mkdir -p "/workspace/build_fullcone/output"
cd "$WORK_DIR"

echo " 正在检查并准备 Header 与 Boot 环境..."

if ! ls boot-*.tar.gz 1> /dev/null 2>&1; then
    echo "📦 未检测到本地环境 (boot缺失)，判定为本地单机运行，触发云端多通道下载..."
    if [ "$DEVICE_TYPE" == "rk35xx" ]; then
        URL_RK="https://github.com/ophub/kernel/releases/download/kernel_rk35xx/${KERNEL_VER}.tar.gz"
        if sudo wget -qO /tmp/env.tar.gz "$URL_RK"; then
            echo "✅ 从 kernel_rk35xx 下载成功"
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
            
            if [ -d "./${KERNEL_VER}" ]; then
                echo "📦 正在展平嵌套目录..."
                sudo mv ./${KERNEL_VER}/* . 2>/dev/null || true
                sudo rm -rf ./${KERNEL_VER}
            fi
        else
            echo "❌ 警告：下载失败！(可能云端也没有这个版本)"
        fi
    fi
fi

if [ ! -d "header_env" ]; then
    sudo mkdir -p header_env
    sudo tar -zxvf header-*.tar.gz -C header_env 2>/dev/null || true
fi

if [ ! -d "boot_env" ]; then
    sudo mkdir -p boot_env
    sudo tar -zxvf boot-*.tar.gz -C boot_env 2>/dev/null || true
fi

if [ ! -f "header_env/.config" ]; then
    sudo find boot_env -name "config-*" -exec cp {} header_env/.config \;
fi

HEADER_DIR=$(realpath $(dirname $(sudo find header_env -name ".config" | head -n 1)))

COMPILER_TXT="/workspace/build_fullcone/kernel_compiler_simple.txt"
if [ ! -f "$COMPILER_TXT" ]; then
    echo -e "\n=================================================="
    echo " 未发现全局记录，启动首次全盘编译器环境扫描..."
    sudo touch "$COMPILER_TXT"
    sudo chmod 777 "$COMPILER_TXT"
    
    sudo find /workspace/kernel -type f -name ".config" 2>/dev/null | while read -r conf_file; do
        relative_path=$(echo "$conf_file" | sed 's|/workspace/kernel/||' | awk -F'/' '{print $1"/"$2}')
        compiler_ver=$(sudo grep -m 1 "CONFIG_CC_VERSION_TEXT=" "$conf_file" | cut -d'=' -f2 | tr -d '"')
        
        if [ -n "$compiler_ver" ]; then
            echo "[$relative_path] -> $compiler_ver" >> "$COMPILER_TXT"
        fi
    done
    
    sort -u "$COMPILER_TXT" -o "$COMPILER_TXT"
    echo "✅ 全局扫描完成！已保存至: $COMPILER_TXT"
    echo -e "=================================================="
fi

echo -e "\n=================================================="
echo " 目标内核编译器版本查岗："
sudo grep "CONFIG_CC_VERSION_TEXT" $HEADER_DIR/.config || sudo head -n 10 $HEADER_DIR/.config
echo -e "==================================================\n"

export GIT_TERMINAL_PROMPT=0

sudo git config --global http.postBuffer 524288000
sudo git config --global http.version HTTP/1.1

if [ -d "$LINUX_DIR/.git" ] || [ -d "$LINUX_DIR/.git_bak" ]; then
    echo "⚡ 发现本地已有源码树，直接重置清理，跳过拉取..."
    cd "$LINUX_DIR"
    sudo mv .git_bak .git 2>/dev/null || true
    sudo git reset --hard HEAD
    sudo git clean -fdx
    cd ..
else
    echo " 未发现本地源码，开始拉取源码树..."
    sudo rm -rf "$LINUX_DIR"
    mkdir "$LINUX_DIR"
    cd "$LINUX_DIR"
    sudo git init

    echo " 正在探测专属分支库 ($REPO_NAME)..."
    if git ls-remote "https://github.com/unifreq/${REPO_NAME}.git" &>/dev/null; then
        echo "✅ 找到定制分支！正在从 unifreq 拉取..."
        sudo git remote add origin "https://github.com/unifreq/${REPO_NAME}.git"
        
        COMMIT_HASH=$(sudo git ls-remote origin | grep -E "refs/tags/v${KERNEL_VER}(\^\{\})?$" | tail -n 1 | awk '{print $1}')
        
        if [ -n "$COMMIT_HASH" ]; then
            echo -e "✅ [Git Tag] 成功锁定目标哈希值: \033[32m$COMMIT_HASH\033[0m"
        else
            echo "⚠️ 未扫描到官方 Tag，唤醒 Python 深度引擎..."
            COMMIT_HASH=$(python3 - <<EOF
import sys, re, urllib.request, json
version = "$KERNEL_VER"
github_token = "$GITHUB_TOKEN"
owner = "unifreq"
repo = "$REPO_NAME"
pattern = re.compile(rf"up(?:date)?\s+to\s+(?:bsp\s+|v)?{re.escape(version)}", re.IGNORECASE)

try:
    for page in range(1, 11):
        url = f"https://api.github.com/repos/{owner}/{repo}/commits?per_page=100&page={page}"
        headers = {'User-Agent': 'Mozilla/5.0'}
        if github_token: headers['Authorization'] = f"token {github_token}"
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req) as response:
            data = json.loads(response.read().decode('utf-8'))
            if not data: break
            for commit in data:
                if pattern.search(commit['commit']['message']):
                    print(commit['sha'])
                    sys.exit(0)
except Exception as e:
    import sys
    print(f"API 请求异常: {e}", file=sys.stderr)
EOF
)
            if [ -n "$COMMIT_HASH" ]; then
                echo -e "✅ [Python] 深度引擎挖掘到历史哈希值: \033[32m$COMMIT_HASH\033[0m"
            fi
        fi

        if [ -n "$COMMIT_HASH" ]; then
            echo "⬇️ 开始按哈希值拉取纯正源码..."
            sudo git fetch --depth 1 origin $COMMIT_HASH
            if [ $? -ne 0 ]; then
                echo -e "\033[31m❌ Git 拉取断流或失败！触发自动清理保护机制...\033[0m"
                sudo rm -rf "$WORK_DIR/boot_env" "$WORK_DIR/header_env" "$LINUX_DIR"
                exit 1
            fi
            
            sudo git checkout FETCH_HEAD
            if [ $? -ne 0 ]; then
                echo -e "\033[31m❌ Git 检出失败！触发自动清理保护机制...\033[0m"
                sudo rm -rf "$WORK_DIR/boot_env" "$WORK_DIR/header_env" "$LINUX_DIR"
                exit 1
            fi
        else
            echo -e "\033[33m⚠️ unifreq 存在仓库，但未找到对应版本(${KERNEL_VER})的提交哈希！放弃 unifreq...\033[0m"
            echo -e "\033[32m 启动官方 Linux 源码直连兜底方案 (Kernel.org)...\033[0m"
            
            sudo git remote set-url origin "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git" 2>/dev/null || sudo git remote add origin "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
            
            sudo git fetch --depth 1 origin "tags/v${KERNEL_VER}"
            
            if [ $? -eq 0 ]; then
                sudo git checkout FETCH_HEAD
                if [ $? -ne 0 ]; then
                    echo -e "\033[31m❌ 官方源码检出失败！触发自动清理保护机制...\033[0m"
                    sudo rm -rf "$WORK_DIR/boot_env" "$WORK_DIR/header_env" "$LINUX_DIR"
                    exit 1
                fi
                echo "✅ 官方源码 v${KERNEL_VER} 兜底拉取完毕！"
            else
                echo -e "\033[31m❌ 灾难性错误：官方源码库中未能拉取到 v${KERNEL_VER} 或拉取断流！\033[0m"
                sudo rm -rf "$WORK_DIR/boot_env" "$WORK_DIR/header_env" "$LINUX_DIR"
                exit 1
            fi
        fi
    else
        echo -e "\033[33m⚠️ unifreq 并不存在 ${REPO_NAME} 仓库！\033[0m"
        echo -e "\033[32m 启动官方 Linux 源码直连兜底方案 (Kernel.org)...\033[0m"
        sudo git remote add origin "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
        
        sudo git fetch --depth 1 origin "tags/v${KERNEL_VER}"
        
        if [ $? -eq 0 ]; then
            sudo git checkout FETCH_HEAD
            if [ $? -ne 0 ]; then
                echo -e "\033[31m❌ 官方源码检出失败！触发自动清理保护机制...\033[0m"
                sudo rm -rf "$WORK_DIR/boot_env" "$WORK_DIR/header_env" "$LINUX_DIR"
                exit 1
            fi
            echo "✅ 官方源码 v${KERNEL_VER} 兜底拉取完毕！"
        else
            echo -e "\033[31m❌ 灾难性错误：官方源码库中未能拉取到 v${KERNEL_VER} 或拉取断流！\033[0m"
                sudo rm -rf "$WORK_DIR/boot_env" "$WORK_DIR/header_env" "$LINUX_DIR"
            exit 1
        fi
    fi
    cd ..
fi

cd "$LINUX_DIR"

echo " 严格执行注入 1/3: 注入地基 .config..."
sudo cp $HEADER_DIR/.config .

sudo sed -i 's/CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/g' .config
if grep -q "CONFIG_LOCALVERSION=" .config; then
    sudo sed -i 's/CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="'"$SIGN_SUFFIX"'"/' .config
else
    echo "CONFIG_LOCALVERSION=\"$SIGN_SUFFIX\"" | sudo tee -a .config > /dev/null
fi

echo "🔒 正在强行锁死 Makefile 内核版本号以确保 Vermagic 100% 匹配..."
SYS_VER_1=$(echo $KERNEL_VER | cut -d. -f1)
SYS_VER_2=$(echo $KERNEL_VER | cut -d. -f2)
SYS_VER_3=$(echo $KERNEL_VER | cut -d. -f3)

sudo sed -i "s/^VERSION = .*/VERSION = $SYS_VER_1/" Makefile
sudo sed -i "s/^PATCHLEVEL = .*/PATCHLEVEL = $SYS_VER_2/" Makefile
sudo sed -i "s/^SUBLEVEL = .*/SUBLEVEL = $SYS_VER_3/" Makefile
sudo sed -i "s/^EXTRAVERSION = .*/EXTRAVERSION = /" Makefile

sudo mv .git .git_bak 2>/dev/null || true

echo "⚙️ 让厂长生成编译工具链与基础骨架..."
sudo $MAKE_CMD olddefconfig
sudo $MAKE_CMD modules_prepare

echo " 严格执行注入 2/3 & 3/3: 雷达寻找并注入 ABI 密码本..."
cd "$WORK_DIR"

echo "  [雷达追踪] 当前搜索大区: $(pwd)"
SYM_FILE=$(sudo find . -type f -name "Module.symvers" | grep -v "$LINUX_DIR" | head -n 1)

if [ -n "$SYM_FILE" ]; then
    echo "✅ 成功抓捕到密码本: $SYM_FILE"
    sudo cp "$SYM_FILE" "$LINUX_DIR/"
else
    echo -e "\033[33m⚠️ 地表未发现 Module.symvers，启动 X 光透视扫描未解压的压缩包...\033[0m"
    for tar_file in *.tar.gz; do
        if [ -f "$tar_file" ]; then
            target_in_tar=$(tar -tf "$tar_file" 2>/dev/null | grep -E '(/|^)Module\.symvers$' | head -n 1)
            if [ -n "$target_in_tar" ]; then
                echo -e "\033[32m✅ 惊人发现！躲在 $tar_file 里面: $target_in_tar\033[0m"
                sudo tar -xOf "$tar_file" "$target_in_tar" 2>/dev/null | sudo tee "$LINUX_DIR/Module.symvers" > /dev/null
                if [ -s "$LINUX_DIR/Module.symvers" ]; then
                    SYM_FILE="EXTRACTED_FROM_TAR"
                    break
                fi
            fi
        fi
    done
    
    if [ -z "$SYM_FILE" ]; then
        echo -e "\033[31m⚠️ 警告: 所有的资源包中均未找到 Module.symvers！\033[0m"
        echo -e "\033[35m🚀 启动核动力模式：自动全量编译内核以强行榨取密码本 (预计耗时较长)...\033[0m"
        cd "$LINUX_DIR"

        echo "🧹 正在启动物理超度加强模式：清洗所有无关驱动和子系统..."
        sudo sed -i '/SFE/d' .config
        sudo sed -i '/FLOWOFFLOAD/d' .config
        sudo sed -i '/SHORTCUT_FE/d' .config
        sudo sed -i 's/^CONFIG_STAGING=y/# CONFIG_STAGING is not set/' .config
        sudo sed -i 's/^CONFIG_MAC80211.*/# CONFIG_MAC80211 is not set/' .config
        sudo sed -i 's/^CONFIG_BATMAN_ADV.*/# CONFIG_BATMAN_ADV is not set/' .config
        sudo sed -i 's/^CONFIG_IEEE802154.*/# CONFIG_IEEE802154 is not set/' .config
        sudo sed -i 's/^CONFIG_MAC802154.*/# CONFIG_MAC802154 is not set/' .config
        sudo sed -i 's/^CONFIG_6LOWPAN.*/# CONFIG_6LOWPAN is not set/' .config
        sudo sed -i 's/^CONFIG_HSR.*/# CONFIG_HSR is not set/' .config
        sudo sed -i 's/^CONFIG_QRTR.*/# CONFIG_QRTR is not set/' .config
        sudo sed -i 's/^CONFIG_CEPH_LIB.*/# CONFIG_CEPH_LIB is not set/' .config
        sudo sed -i 's/^CONFIG_CEPH_FS.*/# CONFIG_CEPH_FS is not set/' .config
        sudo sed -i 's/^CONFIG_HID_\([A-Z0-9_]*\)=.*/# CONFIG_HID_\1 is not set/' .config
        sudo sed -i 's/^CONFIG_UHID.*/# CONFIG_UHID is not set/' .config
        sudo sed -i 's/^CONFIG_R8188EU.*/# CONFIG_R8188EU is not set/' .config
        sudo sed -i 's/^CONFIG_VT6656.*/# CONFIG_VT6656 is not set/' .config
        sudo sed -i 's/^CONFIG_RTL8723BS.*/# CONFIG_RTL8723BS is not set/' .config
        sudo sed -i 's/^CONFIG_IP_SCTP.*/# CONFIG_IP_SCTP is not set/' .config
        sudo sed -i 's/^CONFIG_TIPC.*/# CONFIG_TIPC is not set/' .config
        sudo sed -i 's/^CONFIG_MD.*/# CONFIG_MD is not set/' .config
        sudo sed -i 's/^CONFIG_BLK_DEV_MD.*/# CONFIG_BLK_DEV_MD is not set/' .config
        sudo sed -i 's/^CONFIG_BLK_DEV_DM.*/# CONFIG_BLK_DEV_DM is not set/' .config
        sudo sed -i 's/^CONFIG_MEDIA_SUPPORT=.*/# CONFIG_MEDIA_SUPPORT is not set/' .config
        sudo sed -i 's/^CONFIG_MEDIA_CAMERA_SUPPORT=.*/# CONFIG_MEDIA_CAMERA_SUPPORT is not set/' .config
        sudo sed -i 's/^CONFIG_MEDIA_USB_SUPPORT=.*/# CONFIG_MEDIA_USB_SUPPORT is not set/' .config
        sudo sed -i 's/^CONFIG_V4L_TEST_DRIVERS=.*/# CONFIG_V4L_TEST_DRIVERS is not set/' .config
        sudo sed -i 's/^CONFIG_VIDEO_VIVID=.*/# CONFIG_VIDEO_VIVID is not set/' .config
        sudo sed -i 's/^CONFIG_DRM=.*/# CONFIG_DRM is not set/' .config
        sudo sed -i 's/^CONFIG_FB=.*/# CONFIG_FB is not set/' .config
        sudo sed -i '/cryptodev/d' drivers/crypto/Makefile
        sudo sed -i '/rtl88/d' drivers/net/wireless/Makefile
        sudo sed -i '/rtl81/d' drivers/net/wireless/Makefile
        sudo sed -i '/sfe/d' drivers/net/ethernet/qualcomm/Makefile

        sudo $MAKE_CMD olddefconfig
        sudo $MAKE_CMD clean
        sudo $MAKE_CMD KBUILD_MODPOST_WARN=1 KCFLAGS="-Wno-error" HOSTCFLAGS="-Wno-error" Image modules -j$(nproc)
        
        if [ -f "Module.symvers" ]; then
            echo -e "\033[32m✅ 核动力重铸成功！密码本已生成并在位！\033[0m"
            sudo cp Module.symvers "$WORK_DIR/"
        else
            echo -e "\033[31m❌ 灾难性错误：全量编译失败，无法生成 Module.symvers！即将退出编译。\033[0m"
            exit 1
        fi
        cd "$WORK_DIR"
    fi
fi

cd "$LINUX_DIR"
sudo mkdir -p include/generated
sudo cp $HEADER_DIR/include/generated/autoconf.h include/generated/ 2>/dev/null || true

# =========================================================================
# OAF 特有逻辑剥离，替换为 Fullcone 专属环境
# =========================================================================

echo "🧹 [清理旧环境]..."
sudo rm -rf /workspace/nft-fullcone
mkdir -p "$OUT_DIR"

echo "⬇️ [获取 Fullcone 源码] 从上游克隆 ImmortalWrt 绑定的版本..."
cd /workspace
git clone https://github.com/fullcone-nat-nftables/nft-fullcone.git
cd nft-fullcone
# 锁定到 ImmortalWrt Makefile 里的 Commit Hash
git checkout 07d93b626ce5ea885cd16f9ab07fac3213c355d9

echo "🩹 [注入兼容补丁] 应用 Linux 6.12 兼容性修复..."
# 这里需要补丁文件存在于 GITHUB_WORKSPACE 的 patches 目录下
if [ -f "$GITHUB_WORKSPACE/patches/010-fix-build-with-kernel-6.12.patch" ]; then
    patch -p1 < "$GITHUB_WORKSPACE/patches/010-fix-build-with-kernel-6.12.patch"
else
    echo "⚠️ 警告：未找到 010-fix-build-with-kernel-6.12.patch 补丁，若内核 < 6.12 可忽略。"
fi

echo "🔥 [魔改 ABI 排序] 强制修改头文件顺序，对齐 ImmortalWrt 错误前端 (FLAGS -> MIN -> MAX)..."
perl -0777 -pi -e 's/(\tNFTA_FULLCONE_UNSPEC,\n)\tNFTA_FULLCONE_REG_PROTO_MIN,\n\tNFTA_FULLCONE_REG_PROTO_MAX,\n\tNFTA_FULLCONE_FLAGS,/$1\tNFTA_FULLCONE_FLAGS,\n\tNFTA_FULLCONE_REG_PROTO_MIN,\n\tNFTA_FULLCONE_REG_PROTO_MAX,/g' src/nf_nat_fullcone.h

echo "=================================================="
echo " 校验魔改结果 (确认 FLAGS 已经跑到前面):"
grep -A 5 "enum nft_fullcone_attributes {" src/nf_nat_fullcone.h
echo "=================================================="

echo -e "\n 发起最终极简版纯净编译 (全程无静默，实时监控)..."
# nft_fullcone 的 Makefile 在根目录，但 obj 文件生成在 src 目录
sudo $MAKE_CMD M=$(pwd)/src -C $LINUX_DIR modules

echo -e "\n=================================================="
echo "🎯 最终模块签名验证："
if [ -f "src/nft_fullcone.ko" ]; then
    strings src/nft_fullcone.ko | grep vermagic || echo "⚠️ 警告：提取 vermagic 失败，可能存在未知异常！"
    sudo cp src/nft_fullcone.ko "$OUT_DIR/"
    echo "✅ 成功！定制版 nft_fullcone.ko 已自动提取至: $OUT_DIR/"
else
    echo "❌ 灾难性错误：未找到编译出的 nft_fullcone.ko 文件！"
    exit 1
fi
echo -e "==================================================\n"