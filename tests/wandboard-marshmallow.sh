#!/bin/bash

# set AOSP volume if not already set
export AOSP_VOL=${AOSP_VOL:-~/Development/wandMM}

if [ "$1" = "docker" ]; then
	# here we are in the docker container and try to modify the sources and build them
	. build/envsetup.sh
	lunch wandboard-eng
	date > latestbuild.log; make -j8 2>&1 | tee -a latestbuild.log; date >> latestbuild.log
	
	# likely to fail with:
	# make: *** [out/target/product/wandboard/u-boot.imx] Error 1
	if [ $? -gt 0 ]; then
		echo "STARTING AGAIN" | tee -a latestbuild.log
		date >> latestbuild.log; make -j8 2>&1 | tee -a latestbuild.log; date >> latestbuild.log
	fi

elif [ "$1" = "download" ]; then
	echo "##############################"
	echo "     DOWNLOADING SOURCES"
	echo "##############################"
	
	# download and extract android sources for wandboard
	mkdir -p $AOSP_VOL/aosp
	wget http://download.wandboard.org/wandboard-imx6/android-6.0/wandboard-all-android-6.0.1-fullsource_20160428.tar.xz $AOSP_VOL/wandboard-all-android-6.0.1-fullsource_20160428.tar.xz
	tar xvf $AOSP_VOL/wandboard-all-android-6.0.1-fullsource_20160428.tar.xz -C $AOSP_VOL/aosp/ --strip-components 1
	
	echo ""
	echo "run: $(dirname $0)/$(basename $0) setup"

elif [ "$1" = "patch" ]; then
	# patch NFC support into wandboard sources
	echo "##############################"
	echo "      MODIFIYING KERNEL"
	echo "##############################"

	. build/envsetup.sh
	lunch wandboard-eng
	
	# download driver
	git clone https://github.com/NXPNFCLinux/nxp-pn5xx.git $ANDROID_BUILD_TOP/kernel_imx/drivers/misc/nxp-pn5xx

	# add driver-dir to kernel makefile
	echo "obj-y += nxp-pn5xx/" >> $ANDROID_BUILD_TOP/kernel_imx/drivers/misc/Makefile

	# patch driver to allow for integrated building
	sed -i.bkp -e 's#obj-m :=#obj-$(CONFIG_NFC_NXP_5XX) :=#' $ANDROID_BUILD_TOP/kernel_imx/drivers/misc/nxp-pn5xx/Makefile

	# add driver options to menuconfig
	sed -i.bkp -e 's#endmenu#source \"drivers/misc/nxp-pn5xx/Kconfig\"\nendmenu#' $ANDROID_BUILD_TOP/kernel_imx/drivers/misc/Kconfig

	# dirty patch add driver to kernel config UNTESTED - menuconfig alters too much!
	echo "CONFIG_NFC_NXP_5XX=y" >> $ANDROID_BUILD_TOP/kernel_imx/arch/arm/configs/wandboard_android_defconfig

	# include NFC controller in linux device tree
	patch $ANDROID_BUILD_TOP/kernel_imx/arch/arm/boot/dts/imx6qdl-wandboard.dtsi << EOF
@@ -303,10 +303,23 @@
 };

 &i2c3 {
-        clock-frequency = <100000>;
+        clock-frequency = <400000>;
         pinctrl-names = "default";
         pinctrl-0 = <&pinctrl_i2c3_3>;
         status = "okay";
+
+       pn547: pn547@28 {
+
+               compatible = "nxp,pn547";
+
+               reg = <0x28>;
+               clock-frequency = <400000>;
+
+               interrupt-gpios = <&gpio6 31 0>;
+               enable-gpios = <&gpio3 27 0>;
+               /* nxp,pn54x-clkreq = <&gpio3 12 0>; */
+               /* firmware-gpios = <&gpio1 24 0>; */
+       };
 };

 /*
EOF

	echo "##############################"
	echo "   MODIFYING ANDROID SYSTEM"
	echo "##############################"

	# apply/replace android services with nxp specific code
	rm -rf $ANDROID_BUILD_TOP/external/libnfc-nci
	git clone https://github.com/NXPNFCProject/NFC_NCIHAL_libnfc-nci.git $ANDROID_BUILD_TOP/external/libnfc-nci --branch "NFC_NCIHALx_AR3C.4.5.0_M_OpnSrc"

	rm -rf $ANDROID_BUILD_TOP/packages/apps/Nfc
	git clone https://github.com/NXPNFCProject/NFC_NCIHAL_Nfc.git $ANDROID_BUILD_TOP/packages/apps/Nfc --branch "NFC_NCIHALx_AR3C.4.5.0_M_OpnSrc"

	git clone https://github.com/NXPNFCLinux/nxpnfc_android_marshmallow.git $ANDROID_BUILD_TOP/NxpNfcAndroid
	git clone https://github.com/NXPNFCProject/NXPNFC_Reference.git $ANDROID_BUILD_TOP/NxpNfcAndroid/NXPNFC_Reference --branch "NFC_NCIHALx_AR3C.4.5.0_M_OpnSrc"
	cp $ANDROID_BUILD_TOP/NxpNfcAndroid/NXPNFC_Reference/hardware/libhardware/include/hardware/nfc.h $ANDROID_BUILD_TOP/hardware/libhardware/include/hardware/nfc.h
	git clone https://github.com/NXPNFCProject/NFC_NCIHAL_base.git $ANDROID_BUILD_TOP/NxpNfcAndroid/NFC_NCIHAL_base --branch "NFC_NCIHALx_AR3C.4.5.0_M_OpnSrc"

	# NXP script to perform modifications for PN7120
	bash $ANDROID_BUILD_TOP/NxpNfcAndroid/install_NFC.sh PN7120

	# Add the NFC related packages to the android build
	cat << EOF >> $ANDROID_BUILD_TOP/device/fsl/imx6/wandboard.mk
# NFC packages
PRODUCT_PACKAGES += \
			libnfc-nci \
			libnfc_nci_jni \
			nfc_nci.pn54x.default \
			NfcNci \
			Tag \
			com.android.nfc_extras

PRODUCT_COPY_FILES += \
			frameworks/native/data/etc/com.nxp.mifare.xml:system/etc/permissions/com.nxp.mifare.xml \
			frameworks/native/data/etc/com.android.nfc_extras.xml:system/etc/permissions/com.android.nfc_extras.xml \
			frameworks/native/data/etc/android.hardware.nfc.xml:system/etc/permissions/android.hardware.nfc.xml \
			frameworks/native/data/etc/android.hardware.nfc.hce.xml:system/etc/permissions/android.hardware.nfc.hce.xml \
			NxpNfcAndroid/android.hardware.nfc.hcef.xml:system/etc/permissions/android.hardware.nfc.hcef.xml \
			NxpNfcAndroid/conf/libnfc-brcm.conf:system/etc/libnfc-brcm.conf \
			NxpNfcAndroid/conf/libnfc-nxp.conf:system/etc/libnfc-nxp.conf

EOF

	# add file permissions for device to init.rc
	cat << EOF >> $ANDROID_BUILD_TOP/system/core/rootdir/init.rc
# NFC
	setprop ro.nfc.port "I2C"
	chmod 0660 /dev/pn544
	chown nfc nfc /dev/pn544
EOF

	echo "##############################"
	echo "   READY TO BUILD"
	echo "##############################"
	echo "run: $(dirname $0)/$(basename $0) build"
	echo "or: $(dirname $0)/$(basename $0) shell"

elif [ "$1" = "setupdocker" ]; then
	echo "################################"
	echo "GETTING REPO AND BUILDING DOCKER"
	echo "################################"
	# load docker files and aosp executable to prepare environment
	mkdir -p $AOSP_VOL
	git clone https://github.com/fib1d/docker-aosp.git $AOSP_VOL/docker-aosp
	#cd $AOSP_VOL/docker-aosp
	docker build -t nsvat/aosp:6.0-marshmallow $AOSP_VOL/docker-aosp/
	#cd $(dirname $0)
	echo "run: $(dirname $0)/$(basename $0) download"
	echo "or: $(dirname $0)/$(basename $0) patch"

else
	# start docker container and go into shell via option docker
    aosp_url="https://raw.githubusercontent.com/kylemanna/docker-aosp/master/utils/aosp"
    
	if [ "$1" = "build" ]; then
		args="bash run.sh docker"
	elif [ "$1" = "setup" ]; then
		args="bash run.sh patch"
        elif [ "$1" = "shell" ]; then
                args="bash"

	fi
	
    export AOSP_EXTRA_ARGS="-v $(cd $(dirname $0) && pwd -P)/$(basename $0):/usr/local/bin/run.sh:Z"
    export AOSP_IMAGE="nsvat/aosp:6.0-marshmallow"

	# use olivers patched aosp executable
	AOSP_BIN="$AOSP_VOL/docker-aosp/utils/aosp"

    #
    # Try to invoke the aosp wrapper with the following priority:
    #
    # 1. If AOSP_BIN is set, use that
    # 2. If aosp is found in the shell $PATH
    # 3. Grab it from the web
    #
	if [ -n "$AOSP_BIN" ]; then
            $AOSP_BIN $args
	elif [ -x "../utils/aosp" ]; then
            ../utils/aosp $args
	elif [ -n "$(type -P aosp)" ]; then
            aosp $args
	fi
fi
