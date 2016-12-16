#!/bin/bash -e

#
# Optional Environment Variables:
#   AKBUILD_CHECK_NEW_CONFIG: If this variable contains a string
#     with length>0, then the build script will abort if there are
#     new configuration options that need to be accounted for in
#     the config file.
#   AKBUILD_CHECK_CONFIG_CHANGE: If this variable contains a string
#     with length>0, then the build script will abort if the config
#     file resulting from "make oldconfig" differs from the original
#     checked-in config.
#   AKBUILD_TECH_DEBT_REPORT: If this variable contains a string
#     with length>0, then akgroup will execute after a quilt build,
#     and store the resulting report at: $TOP/$arch/tech-debt.csv.
#

## exit_usage
#
# Print the usage message and then exit. If no exit value is provided
# as a parameter, then we use an exitvalue of 1 (error).
#
exit_usage() {
        declare exitval=${1:-1}
        cat <<EOF >&2

Build the CHT kernel (i386 and/or x86_64)

USAGE:
	cht-build.sh [ -h | -? ] [ [ -c ] -a ARCH ] [ -o OUTPUT_DIR ] \
		[ -i | -d ] [ DIR ]

	i = do git quiltimport only
	c = compile only - do not reinitialize the source tree
	d = compile debug only
	a = specify just one architecture: x86_64 or i386
	o = directory to place the output of the kernel build
		without disturbing the original source tree
	DIR = directory other than gmin-quilt-representation/linux
		where tree should be created

EOF
	exit $exitval
}

. build_common.sh # Include library of common build functions
CCACHE=1	# Enable ccache

KERNEL_VERSION=$GMIN_KERNEL_VERSION	# See build_common.sh

# Set Build User and Host such that we see (android@cht) in /proc/version
export KBUILD_BUILD_USER=android
export KBUILD_BUILD_HOST=cht

# process_arguments sets the $OPT_x variables
OPTION_STRING="a:chido:?"
process_arguments $@

# Display usage and exit with the specified error code
$OPT_exit_only && exit_usage $OPT_exit_code

# cht_prep_quilt
#
# Prepare the series file and the patches for the cht quilt
#
cht_prep_quilt() {
	pushd $KPATH || die "cht_prep_quilt: Failed cd to $KPATH: $?"
	rm -fr patches
	if ! $OPT_debug_only; then
		ln -s $TOP/uefi/cht/patches . || \
			die "cht_prep_quilt: Failed symlink of patches: $?"
	else
		rsync -avz $TOP/uefi/cht/patches/* $PWD/patches/ || \
			die "cht_prep_quilt: Failed rsync of cht patches: $?"
		rsync -avz $TOP/uefi/cht/debug_patches/* $PWD/patches/ \
			--exclude=series --exclude="*_debug_defconfig" || \
			die "cht_prep_quilt: Failed rsync of cht debug patches: $?"
		cat $TOP/uefi/cht/debug_patches/series >> $PWD/patches/series || \
			die "cht_prep_quilt: Failed to cat cht debug series: $?"
	fi
	popd
}

## build_cht
#
# Build CHT for the specified architecture
#
build_cht() {
	declare arch=$1

	if $OPT_import_only; then
		cat $TOP/uefi/cht/${arch}_defconfig \
			$TOP/uefi/cht/debug_patches/${arch}_debug_defconfig > \
			$TOP/uefi/cht/${arch}_debug_defconfig
		git_quilt_import cht_prep_quilt \
			$TOP/uefi/cht/${arch}_defconfig \
			$TOP/uefi/cht/${arch}_debug_defconfig
		exit 0;
	elif $OPT_compile_only; then
		# assuming a .config is already there, just add the version info
		add_extra_version_string $KERNEL_OUTPUT_PATH/.config
		git_build_kernel $arch $TOP/uefi/cht/${arch}_defconfig \
			arch/$arch/boot/bzImage
	elif $OPT_debug_only; then
		cat $TOP/uefi/cht/${arch}_defconfig \
			$TOP/uefi/cht/debug_patches/${arch}_debug_defconfig > \
			$TOP/uefi/cht/tmp_defconfig
		unset AKBUILD_CHECK_CONFIG_CHANGE
		setup_config $TOP/uefi/cht/tmp_defconfig
		git_build_kernel $arch $TOP/uefi/cht/tmp_defconfig \
			arch/$arch/boot/bzImage
	else
		setup_config $TOP/uefi/cht/${arch}_defconfig
		git_build_kernel $arch $TOP/uefi/cht/${arch}_defconfig \
			arch/$arch/boot/bzImage
		technical_debt $arch
	fi

	### Building external modules section
	# Only temporary, this needs to have checks for kernel src,
	# platform we're building for, etc...
	build_modules $arch \
		$TOP/uefi/cht/modules/perftools-external/socperfdk/src \
		$TOP/uefi/cht/modules/perftools-external/socwatchdk/src \
		$TOP/uefi/cht/modules/perftools-external/vtunedk/src \
		$TOP/uefi/cht/modules/perftools-external/vtunedk/src/pax \
		$TOP/uefi/cht/modules/realtek

	build_fedcore $arch $TOP/modules/fedcore $TOP/fedcore
	build_iwlwifi $arch $TOP/uefi/cht/modules/iwlwifi cht_hr
	build_bcmdhd $arch $TOP/uefi/cht/modules/bcmdhd PCIE BCM4356
	build_bcmdhd $arch $TOP/uefi/cht/modules/bcmdhd SDIO BCM43241
	if $OPT_debug_only; then
		build_modules $arch \
			$TOP/uefi/cht/modules/perftools-internal/sepdk/src \
			$TOP/uefi/cht/modules/perftools-internal/socwatchdk/src \
			$TOP/uefi/cht/modules/dbgtools-internal/lmdk/
	fi
	### End of external modules section

	#gather the SRC from the build:
	cd $TOP || die "Failed to cd to $TOP: $?"
	[ -d .git ] && git clean -xdf uefi/cht/modules

	cd $TOP/$arch || die "Failed to cd to $TOP/${arch}: $?"
	if ! $OPT_debug_only; then
		tar -czf src.tgz ../bin/patch ../bin/minigzip \
			../uefi/cht/*_defconfig \
			../uefi/cht/patches \
			../uefi/cht/modules/perftools-external \
			../uefi/cht/modules/realtek \
			../uefi/cht/modules/iwlwifi \
			../modules/fedcore \
			../build_common.sh \
			../cht-build.sh
	fi

	collect_modules $arch

	cd $TOP || die "Failed to cd to $TOP: $?"
	[ -d .git ] && git log -n 1 > $TOP/$arch/source.sha1
	if ! $OPT_debug_only; then
		tar -czf android-kernel-prebuilds-${arch}.tgz $arch
	else
		tar -czf android-kernel-prebuilds-${arch}-debug.tgz $arch bin/
	fi
}

#
# MAIN SCRIPT
#
if [ "$OPT_arch" != "x86_64" ] && \
   [ "$OPT_arch" != "i386" ] && \
   [ "$OPT_arch" != "DEFAULT" ]; then
	warn
	warn "Invalid architecture: $OPT_arch"
	exit_usage 1
fi

if ! $OPT_compile_only || [ ! -d $KPATH/.git ]; then
	kernel_init false
fi

# By resetting the quilt here - we avoid doing it twice (for each arch)
if ! $OPT_compile_only && ! $OPT_import_only; then
	quilt_reset cht_prep_quilt
fi

if [ "$OPT_arch" = "i386" ]; then
	build_cht i386
else
	build_cht x86_64
fi

exit 0
