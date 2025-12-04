#!/bin/bash

# =============================================================================
# Android内核构建脚本
# 版本: 2.0
# =============================================================================

# 颜色定义
yellow='\033[0;33m'
white='\033[0m'
red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
cyan='\033[0;36m'

# 输出带颜色的消息函数
color_echo() {
    local color=$1
    shift
    echo -e "${color}$*${white}"
}

# 打印分隔线
print_separator() {
    color_echo "$cyan" "=============================================="
}

# 打印步骤标题
print_step() {
    local step_name="$1"
    print_separator
    color_echo "$green" "$step_name"
    print_separator
}

# 错误处理函数
error_exit() {
    color_echo "$red" "错误: $1"
    exit 1
}

# 成功函数
print_success() {
    color_echo "$green" "✓ $1"
}

# 信息函数
print_info() {
    color_echo "$blue" "ℹℹ $1"
}

# 警告函数
print_warning() {
    color_echo "$yellow" "警告: $1"
}

# 确保脚本在出错时退出
set -e

# --- 动态定位脚本目录 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || {
    error_exit "无法切换到脚本所在目录: $SCRIPT_DIR"
}

# --- 参数解析 ---
print_step "参数解析"

# 初始化变量
TARGET_DEVICE=""
KSU_ENABLED=false
BUILD_AOSP=false
BUILD_MIUI=false

# 显示使用说明
show_usage() {
    color_echo "$yellow" "用法: $0 <设备名称> [ksu] [--aosp|--miui]"
    color_echo "$yellow" "示例:"
    color_echo "$yellow" "  $0 alioth                    # 构建标准版本"
    color_echo "$yellow" "  $0 alioth ksu               # 构建KernelSU版本"
    color_echo "$yellow" "  $0 alioth --aosp            # 仅构建AOSP版本"
    color_echo "$yellow" "  $0 alioth ksu --miui        # 构建MIUI+KernelSU版本"
    echo
    color_echo "$yellow" "可用设备:"
    if [[ -d "$SCRIPT_DIR/arch/arm64/configs" ]]; then
        ls "$SCRIPT_DIR/arch/arm64/configs/"*_defconfig 2>/dev/null | 
            sed "s|.*/||; s|_defconfig||" | xargs printf "  %s\n" || 
            color_echo "$red" "  无法读取设备配置目录"
    else
        color_echo "$red" "  配置目录不存在"
    fi
}

# 解析参数
if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

# 检查帮助参数
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    show_usage
    exit 0
fi

# 第一个参数是设备名称
TARGET_DEVICE="$1"
shift

# 处理选项参数
while [ $# -gt 0 ]; do
    case "$1" in
        ksu)
            KSU_ENABLED=true
            print_info "启用KernelSU支持"
            shift
            ;;
        --aosp)
            BUILD_AOSP=true
            print_info "构建AOSP版本"
            shift
            ;;
        --miui)
            BUILD_MIUI=true
            print_info "构建MIUI版本"
            shift
            ;;
        *)
            print_info "忽略未知选项: $1"
            shift
            ;;
    esac
done

# 如果没有指定构建类型，默认构建两者
if [ "$BUILD_AOSP" = false ] && [ "$BUILD_MIUI" = false ]; then
    BUILD_AOSP=true
    BUILD_MIUI=true
    print_info "默认构建AOSP和MIUI版本"
fi

# 验证必需参数
if [ -z "$TARGET_DEVICE" ]; then
    error_exit "目标设备不能为空"
fi

# 检查设备配置
if [[ ! -f "$SCRIPT_DIR/arch/arm64/configs/${TARGET_DEVICE}_defconfig" ]]; then
    error_exit "未找到目标设备 [$TARGET_DEVICE] 的配置"
fi

print_success "参数解析完成"

# --- 环境配置 ---
print_step "环境配置"

# 工具链路径设置
TOOLCHAIN_PATH="${TOOLCHAIN_PATH:-$HOME/zyc-clang}"
if [ ! -d "$TOOLCHAIN_PATH" ]; then
    error_exit "工具链路径不存在: $TOOLCHAIN_PATH"
fi

print_info "工具链路径: $TOOLCHAIN_PATH"
export PATH="$TOOLCHAIN_PATH/bin:$PATH"

# 检查必要的工具
print_info "检查编译工具..."
if ! command -v clang >/dev/null 2>&1; then
    error_exit "未找到clang"
fi

# 设置ccache
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache_mikernel}"
mkdir -p "$CCACHE_DIR"
export CC="ccache clang"
export PATH="/usr/lib/ccache:$PATH"
print_info "已启用ccache"

# Git信息
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD 2>/dev/null || echo "unknown")

# 构建配置
print_step "构建配置摘要"
color_echo "$cyan" "目标设备:    $TARGET_DEVICE"
color_echo "$cyan" "KernelSU:    $($KSU_ENABLED && echo "启用" || echo "禁用")"
color_echo "$cyan" "构建AOSP:    $($BUILD_AOSP && echo "是" || echo "否")"
color_echo "$cyan" "构建MIUI:    $($BUILD_MIUI && echo "是" || echo "否")"
color_echo "$cyan" "Git Commit:  $GIT_COMMIT_ID"

print_separator

# --- 构建目录管理 ---
print_step "构建目录设置"

BUILD_DIR="../build_${TARGET_DEVICE}_${GIT_COMMIT_ID}"
print_info "使用独立构建目录: $BUILD_DIR"
mkdir -p "$BUILD_DIR"

# --- 构建函数（按正确的调用顺序定义）---

setup_kernelsu() {
    if ! $KSU_ENABLED; then
        return 0
    fi
    
    print_step "设置KernelSU"
    
    curl -LSs "https://raw.githubusercontent.com/ApartTUSITU/SukiSU-Ultra/main/kernel/setup.sh" | bash -s ApartTUSITU
    
    # 设置版本信息
    if [ -f "KernelSU/kernel/Makefile" ]; then
        local version=$(grep 'KSU_VERSION_API :=' "KernelSU/kernel/Makefile" | awk -F':=' '{print $2}' | xargs)
        if [ -n "$version" ]; then
            sed -i "s|KSU_VERSION_FULL :=.*|KSU_VERSION_FULL := v${version}-且听风吟|" "KernelSU/kernel/Makefile"
            print_info "KernelSU版本: v$version"
        fi
    fi
    
    print_success "KernelSU设置完成"
}

setup_version_info() {
    print_info "设置版本信息..."
    
    # 设置版本文件
    echo 1 > "$BUILD_DIR/.version"
    
    # 设置构建环境变量
    export KBUILD_BUILD_VERSION="1"
    export LOCALVERSION="-g92c089fc2d37"
    export KBUILD_BUILD_USER="xiaomi-builder"
    export KBUILD_BUILD_HOST="xiaomi-build-server"
    export KBUILD_BUILD_TIMESTAMP="Wed Oct 29 11:41:46 UTC 2025"
    
    print_success "版本信息设置完成"
}

prepare_anykernel() {
    print_step "准备AnyKernel3"
    
    if [ ! -d "anykernel" ]; then
        git clone https://github.com/liyafe1997/AnyKernel3 -b kona --single-branch --depth=1 anykernel
        print_success "AnyKernel3下载成功"
    else
        print_info "使用现有的AnyKernel3目录"
    fi
}

# --- KPM 补丁函数 ---
patch_kpm() {
    if ! $KSU_ENABLED; then
        return 0
    fi
    
    print_step "应用KPM补丁"
    
    local image_dir="$BUILD_DIR/arch/arm64/boot"
    cd "$image_dir"
    
    # 下载并应用补丁
    if curl -LSs "https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.12.2/patch_linux" -o patch; then
        chmod +x patch
        if ./patch; then
            rm -f Image
            mv oImage Image
            print_success "KPM补丁应用成功"
        else
            print_warning "KPM补丁应用失败，使用原始镜像"
        fi
        rm -f patch
    else
        print_warning "无法下载KPM补丁，使用原始镜像"
    fi
    
    cd "$SCRIPT_DIR"
}

# --- 统一的镜像打包函数 ---
Image_Repack() {
    local system_type=$1
    
    print_step "打包${system_type}镜像"
    
    # 检查内核镜像
    local image_path="$BUILD_DIR/arch/arm64/boot/Image"
    if [ ! -f "$image_path" ]; then
        error_exit "未找到内核镜像 [$image_path]"
    fi
    print_success "找到内核镜像: $image_path"

    # KPM补丁
    if $KSU_ENABLED; then
        patch_kpm
    fi

    # 生成DTB
    local dtb_path="$BUILD_DIR/arch/arm64/boot/dtb"
    print_info "生成DTB文件: $dtb_path"
    find "$BUILD_DIR/arch/arm64/boot/dts" -name '*.dtb' -exec cat {} + > "$dtb_path" 2>/dev/null || {
        print_warning "未找到DTB文件，创建空文件"
        touch "$dtb_path"
    }

    # 准备AnyKernel3
    if [ ! -d "anykernel" ]; then
        print_info "下载AnyKernel3..."
        if git clone https://github.com/liyafe1997/AnyKernel3 -b kona --single-branch --depth=1 anykernel; then
            print_success "AnyKernel3下载成功"
        else
            error_exit "AnyKernel3下载失败"
        fi
    else
        print_info "使用现有的AnyKernel3目录"
    fi

    # 清理并准备内核文件
    rm -rf anykernel/kernels/
    mkdir -p anykernel/kernels/

    cp "$image_path" anykernel/kernels/
    cp "$dtb_path" anykernel/kernels/

    # 创建刷机包文件名
    local ksu_str=$($KSU_ENABLED && echo "SukiSU" || echo "NoKernelSU")
    local timestamp=$(date +'%Y%m%d_%H%M%S')
    local zip_filename="Kernel_${system_type}_${TARGET_DEVICE}_${ksu_str}_${timestamp}_anykernel3_${GIT_COMMIT_ID}.zip"

    # 创建刷机包
    print_info "创建刷机包: $zip_filename"
    cd anykernel
    if zip -r9 "$zip_filename" ./* -x .git .gitignore out/ ./*.zip 2>/dev/null; then
        mv "$zip_filename" ../
        print_success "刷机包创建成功: $zip_filename"
    else
        error_exit "刷机包创建失败"
    fi
    cd ..

    print_success "${system_type}镜像打包完成"
}

# --- 内核构建函数 ---
build_kernel() {
    local system_type=$1
    
    print_step "构建$system_type内核"
    
    # 清理构建目录
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    
    # 设置版本信息
    setup_version_info
    
    # 基本make参数
    local MAKE_ARGS=(
        "O=$BUILD_DIR"
        "ARCH=arm64" 
        "SUBARCH=arm64"
        "CC=clang"
        "CROSS_COMPILE=aarch64-linux-gnu-"
        "CROSS_COMPILE_ARM32=arm-linux-gnueabi-"
        "CROSS_COMPILE_COMPAT=arm-linux-gnueabi-"
        "CLANG_TRIPLE=aarch64-linux-gnu-"
        "-j$(nproc)"
    )
    
    # 配置defconfig
    print_info "配置defconfig..."
    make "${MAKE_ARGS[@]}" "${TARGET_DEVICE}_defconfig"
    
    # KernelSU配置
    if $KSU_ENABLED; then
        print_info "配置KernelSU..."
        scripts/config --file "$BUILD_DIR/.config" \
            -e KSU \
            -e KSU_SUSFS_HAS_MAGIC_MOUNT \
            -e KSU_SUSFS \
            -e KSU_SUSFS_SUS_PATH \
            -e KSU_SUSFS_SUS_MOUNT \
            -e KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT \
            -e KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT \
            -e KSU_SUSFS_SUS_KSTAT \
            -e KSU_SUSFS_TRY_UMOUNT \
            -e KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT \
            -e KSU_SUSFS_SPOOF_UNAME \
            -e KSU_SUSFS_ENABLE_LOG \
            -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
            -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
            -e KSU_SUSFS_OPEN_REDIRECT \
            -e KSU_SUSFS_SUS_MAP \
            -e KPM
    else
        scripts/config --file "$BUILD_DIR/.config" -d KSU
    fi
    
    # MIUI配置
    if [ "$system_type" = "MIUI" ]; then
        print_info "应用MIUI配置..."
        scripts/config --file "$BUILD_DIR/.config" \
            --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
            -e PERF_CRITICAL_RT_TASK \
            -e SF_BINDER \
            -e OVERLAY_FS \
            -d DEBUG_FS \
            -e MIGT \
            -e MIGT_ENERGY_MODEL \
            -e MIHW \
            -e PACKAGE_RUNTIME_INFO \
            -e BINDER_OPT \
            -e KPERFEVENTS \
            -e MILLET \
            -e PERF_HUMANTASK \
            -d LTO_CLANG \
            -d LOCALVERSION_AUTO \
            -e XIAOMI_MIUI \
            -d MI_MEMORY_SYSFS \
            -e TASK_DELAY_ACCT \
            -e MIUI_ZRAM_MEMORY_TRACKING \
            -d CONFIG_MODULE_SIG_SHA512 \
            -d CONFIG_MODULE_SIG_HASH \
            -e MI_FRAGMENTION \
            -e PERF_HELPER \
            -e BOOTUP_RECLAIM \
            -e MI_RECLAIM \
            -e RTMM
    fi
    
    # 开始编译
    local start_time=$(date +%s)
    print_info "开始编译..."
    make "${MAKE_ARGS[@]}"
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # 检查编译结果
    if [ ! -f "$BUILD_DIR/arch/arm64/boot/Image" ]; then
        error_exit "未找到内核镜像"
    fi
    
    print_success "${system_type}内核编译完成，耗时: $((duration / 60))分$((duration % 60))秒"
    
    # 打包镜像
    Image_Repack "$system_type"
}

modify_miui_dts() {
    if [ "$1" != "MIUI" ]; then
        return 0
    fi
    
    print_step "修改MIUI设备树"
    
    local dts_source="arch/arm64/boot/dts/vendor/qcom"
    if [ ! -d "$dts_source" ]; then
        print_info "设备树目录不存在，跳过修改"
        return 0
    fi
    
    # 备份dts
    cp -a "${dts_source}" .dts.bak
    
    # 面板尺寸修正
    color_echo "$yellow" "修正面板尺寸..."
    sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j1s*
    sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j2*
    sed -i 's/<155>/<1544>/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
    sed -i 's/<155>/<1545>/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
    sed -i 's/<155>/<1546>/g' ${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
    sed -i 's/<155>/<1546>/g' ${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
    sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
    sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
    sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
    sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
    sed -i 's/<71>/<710>/g' ${dts_source}/dsi-panel-j1s*
    sed -i 's/<71>/<710>/g' ${dts_source}/dsi-panel-j2*

    # 启用智能FPS
    color_echo "$yellow" "启用智能FPS功能..."
    sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
    sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' ${dts_source}/dsi-panel*
    sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
    sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' ${dts_source}/dsi-panel*

    # 刷新率支持
    color_echo "$yellow" "配置刷新率支持..."
    sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi
    sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi
    sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi
    sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi

    # 亮度控制
    color_echo "$yellow" "配置亮度控制..."
    sed -i 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
    sed -i 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi
    sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
    sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
    sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
    sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
    sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${dts_source}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${dts_source}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi

    print_info "MIUI设备树修改完成"
}

restore_miui_dts() {
    if [ -d ".dts.bak" ]; then
        rm -rf "arch/arm64/boot/dts/vendor/qcom"
        mv .dts.bak "arch/arm64/boot/dts/vendor/qcom"
        print_info "设备树恢复完成"
    fi
}

# --- 主执行流程 ---
main() {
    print_step "开始内核构建流程"
    local start_time=$(date +%s)
    
    # 设置KernelSU
    setup_kernelsu
    
    # 准备AnyKernel3
    prepare_anykernel
    
    # 构建AOSP内核
    if $BUILD_AOSP; then
        build_kernel "AOSP"
    fi
    
    # 构建MIUI内核
    if $BUILD_MIUI; then
        modify_miui_dts "MIUI"
        build_kernel "MIUI"
        restore_miui_dts
    fi
    
    local end_time=$(date +%s)
    local total_duration=$((end_time - start_time))
    
    print_step "构建完成"
    print_success "内核构建全部完成! 总耗时: $((total_duration / 60))分$((total_duration % 60))秒"
    
    # 显示生成的刷机包
    print_info "生成的刷机包:"
    ls -la *.zip 2>/dev/null || print_info "未找到刷机包文件"
}

# 执行主函数
main "$@"
