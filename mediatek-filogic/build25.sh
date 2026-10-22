#!/bin/bash
source shell/apk-custom-packages.sh
#echo "✅ 你选择了第三方软件包：$CUSTOM_PACKAGES"
if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  # ============= 同步第三方插件库==============
  # 同步第三方软件仓库run/apk
  echo "🔄 正在同步第三方软件仓库 Cloning apk file repo..."
  git clone --depth=1 https://github.com/wukongdaily/apk.git /tmp/store-apk-repo

  # 拷贝 run/arm64 下所有 run 文件和apk文件 到 extra-packages 目录
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-apk-repo/run/arm64-a53/* /home/build/immortalwrt/extra-packages/

  echo "✅ Run files copied to extra-packages:"
  # 解压并拷贝apk到packages目录
  sh shell/apk-prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
fi



# yml 传入的路由器型号 PROFILE
echo "Building for profile: $PROFILE"

echo "Include Docker: $INCLUDE_DOCKER"
echo "Create pppoe-settings"
mkdir -p  /home/build/immortalwrt/files/etc/config

# 创建pppoe配置文件 yml传入pppoe变量————>pppoe-settings文件
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting build process..."


# 定义所需安装的包列表 下列插件你都可以自行删减
PACKAGES=""
PACKAGES="$PACKAGES curl luci luci-i18n-base-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
#PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"


# 第三方软件包 合并
# ======== shell/apk-custom-packages.sh =======
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"


# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# 若构建openclash 则添加内核
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    # Download clash_meta
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    # Download GeoIP and GeoSite
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    # Download latest openclash Client
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*apk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest apk: $URL"
    wget "$URL" -P /home/build/immortalwrt/packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi


# 构建镜像
if [ "$PROFILE" = "cudy_tr3000-v1" ]; then
    echo "🔧 正在为 cudy_tr3000-v1 修补 112M 大分区 DTB (0x4000000 -> 0x7000000)..."
    KDIR="/home/build/immortalwrt/build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_filogic"
    DTB_FILE="$KDIR/image-mt7981b-cudy-tr3000-v1.dtb"
    KERNEL_FIT="$KDIR/cudy_tr3000-v1-kernel.bin"
    DTC=$(find "$KDIR" /home/build/immortalwrt/staging_dir/host/bin -name dtc -type f -executable | head -n 1)

    if [ -n "$DTC" ] && [ -f "$DTB_FILE" ] && [ -f "$KDIR/Image" ]; then
        "$DTC" -I dtb -O dts -o /tmp/tr3000.dts "$DTB_FILE"
        sed -i 's/0x5c0000 0x0*4000000/0x5c0000 0x7000000/g' /tmp/tr3000.dts
        grep -A 4 "partition@5c0000" /tmp/tr3000.dts
        "$DTC" -I dts -O dtb -o "$DTB_FILE" /tmp/tr3000.dts

        LINUX_VER=$(sed -n 's/^KERNEL_VERSION:=//p' /home/build/immortalwrt/include/version.mk | tr -d '[:space:]')
        cp "$KDIR/Image" "$KERNEL_FIT"
        /home/build/immortalwrt/staging_dir/host/bin/lzma e "$KERNEL_FIT" -lc1 -lp2 -pb2 "$KERNEL_FIT.new" && mv "$KERNEL_FIT.new" "$KERNEL_FIT"
        /home/build/immortalwrt/scripts/mkits.sh \
            -D cudy_tr3000-v1 -o "$KERNEL_FIT.its" -k "$KERNEL_FIT" \
            -C lzma -d "$DTB_FILE" -a 0x48000000 -e 0x48000000 \
            -c "config-1" -A arm64 -v "$LINUX_VER"
        PATH="$(dirname "$DTC"):/home/build/immortalwrt/staging_dir/host/bin:$PATH" \
            /home/build/immortalwrt/staging_dir/host/bin/mkimage -f "$KERNEL_FIT.its" "$KERNEL_FIT.new" && mv "$KERNEL_FIT.new" "$KERNEL_FIT"
        rm -f "$KERNEL_FIT.its" /tmp/tr3000.dts

        sed -i '/define Device\/cudy_tr3000-v1$/,/^endef$/s/IMAGE_SIZE := 65536k/IMAGE_SIZE := 114688k/' /home/build/immortalwrt/target/linux/mediatek/image/filogic.mk
        echo "✅ cudy_tr3000-v1 112M 大分区内核与 DTB 重新打包完成！"
    else
        echo "⚠️ 未找到 dtc 或 DTB 文件，跳过 112M 补丁"
    fi
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE=$PROFILE PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files"

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
