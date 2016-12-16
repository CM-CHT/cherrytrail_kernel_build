#!/bin/bash

#
# Common code used by kernel build scripts
#

#
# The build scripts for GMIN and for kernels that are based on GMIN
# should set KERNEL_VERSION to $GMIN_KERNEL_VERSION. GMIN_KERNEL_VERSION
# is the one location to update the kernel version for these kernels.
#
GMIN_KERNEL_VERSION=v3.14.37

# General use environment variables
TOP=$PWD
export PATH="$TOP/bin:$PATH"
NPROC=`nproc`
KPATH=${KPATH:-$TOP/linux}
KERNEL_OUTPUT_PATH=${KERNEL_OUTPUT_PATH:-$KPATH}
MAKEOPT_OUTPUT=

# We make .git inaccessible around kernel builds to avoid "-dirty" being
# appended to the kernel version. If we exit abnormally during this
# window of time, we need to cleanup on the way out.
trap "chmod 775 $KPATH/.git" SIGHUP SIGINT SIGTERM

## die
#
# Print an error message to stderr and then exit with error status
#
die() {
	echo "$@" >&2
	chmod 775 $KPATH/.git
	exit 1
}

## warn
#
# Print an error message to stderr
#
warn() {
	echo "$@" >&2
}


## quilt_push_all
#
# Perform quilt push -a
#
quilt_push_all() {
	export QUILT_REFRESH_ARGS="--diffstat --no-timestamps --backup --no-index"
	export QUILT_DIFF_OPTS="--show-c-function"
	export QUILT_PATCH_OPTS="--fuzz=0"

	test -d .pc/ && rm -rf .pc/
	quilt push -a || die "quilt_push_all: quilt push -a failed: $?"
}


## git_quilt_import
#
# For the import cases that require assembling of the quilt (e.g cht, bxt),
# "git quiltimport" is preferred over "quilt -push"
#
git_quilt_import() {
	declare prep_callback=$1
	declare config=$2
	declare debug_config=$3

	pushd $KPATH || die "git_quilt_import: Cannot cd to $KPATH: $?"
	prepare_quilt $prep_callback
	git quiltimport --patches $KPATH/patches || \
		die "git_quilt_import: Failed git quiltimport; $?"
	cp $config $KPATH/arch/x86/configs/ || \
		die "git_quilt_import: Failed to copy $config: $?"
	git add $KPATH/arch/x86/configs/$(basename $config)
	if [ -n "$debug_config" ] ; then
		cp $debug_config $KPATH/arch/x86/configs/ || \
			die "git_quilt_import: Failed to copy $debug_config: $?"
		git add $KPATH/arch/x86/configs/$(basename $debug_config)
	fi
	git commit -m "OAK addtion of defconfig files" \
		-m "Addition of the config and debug config files."
	cd $KERNEL_OUTPUT_PATH  || \
		die "git_quilt_import: Failed to cd to $KERNEL_OUTPUT_PATH: $?"
	cp $config .config || \
		die "git_quilt_import: Failed to copy $config: $?"
	add_extra_version_string .config
	popd
}


## init_compile_flags
#
# Set up for cross compile, and enable ccache if the CCACHE variable is
# set. These need to be set in advance of kernel and/or module builds.
#
init_compile_flags() {

	YOCTO_REPO_TARGET_TOOLS=${ANDROID_BUILD_TOP}/prebuilts/gcc/linux-x86/x86/x86_64-linux-poky/sysroots/x86_64-pokysdk-linux/usr/bin/x86_64-poky-linux
	YOCTO_LOCAL_TARGET_TOOLS=/opt/poky/1.8/sysroots/x86_64-pokysdk-linux/usr/bin/x86_64-poky-linux
	# If TARGET_TOOLS is not already defined or not pointing to a valid toolchain
	# point to yocto toolchain stored in repo if present
	# else exit and display an error message
	if [ -d ${YOCTO_REPO_TARGET_TOOLS} ]; then
		TARGET_TOOLS=${TARGET_TOOLS:-$YOCTO_REPO_TARGET_TOOLS}
	else
		TARGET_TOOLS=${TARGET_TOOLS:-$YOCTO_LOCAL_TARGET_TOOLS}
	fi

	if [ ! -d "${TARGET_TOOLS}" ]; then
		echo "The build kernel requires a toolchain installed" >&2
		echo "The recommanded toolchain is the yocto toolchain" >&2
		echo "It should be available in $YOCTO_REPO_TARGET_TOOLS" >&2
		echo "Sync your manifest if it is not present" >&2
		echo "\nYou can also get your local copy" >& 2
		echo "wget http://mtgdev.jf.intel.com/poky-glibc-x86_64-meta-toolchain-core2-64-toolchain-1.8.sh" >& 2
		echo "sudo ./poky-glibc-x86_64-meta-toolchain-core2-64-toolchain-1.8.sh" >& 2
		echo "It was built using yocto 1.8.x or fido branch (e2e522a)." >& 2
		echo " \"bitbake meta-toolchain\" with a local.conf file" >& 2
		echo "setting the \"MACHINE = qemux86-64\"" >& 2
		exit 1
	fi

	echo "INFO: Building Kernel with ${TARGET_TOOLS} toolchain"
	if [ -n "$CCACHE" ]; then
		CROSS_COMPILE="ccache $TARGET_TOOLS/x86_64-poky-linux-"
	else
		CROSS_COMPILE="$TARGET_TOOLS/x86_64-poky-linux-"
	fi
	export CROSS_COMPILE
}


## build_iwlwifi
#
# Build iwlwifi module
#
build_iwlwifi() {
	declare arch=$1
	declare iwlwifi=$2
	declare iwl_defconfig=$3

	if [ -z $iwl_defconfig ]; then
		declare iwl_defconfig=iwlwifi-public
	fi

	# Turn off ccache for this modules as there are build error with it.
	CCACHE_SAV=$CCACHE
	CCACHE=
	init_compile_flags
	pushd $TOP || die "build_iwlwifi: Cannot cd to $TOP: $?"
	make ARCH=$arch INSTALL_MOD_PATH=$TOP/$arch -C \
		$iwlwifi CROSS_COMPILE=$CROSS_COMPILE \
		KLIB_BUILD=$KERNEL_OUTPUT_PATH clean || \
		die "build_iwlwifi: Failed make clean: $?"
	make ARCH=$arch INSTALL_MOD_PATH=$TOP/$arch \
		-C $iwlwifi CROSS_COMPILE=$CROSS_COMPILE \
		KLIB_BUILD=$KERNEL_OUTPUT_PATH defconfig-$iwl_defconfig || \
		die "build_iwlwifi: Failed make defconfig, using $iwl_defconfig defconfig: $?"
	make ARCH=$arch INSTALL_MOD_PATH=$TOP/$arch \
		-C $iwlwifi CROSS_COMPILE=$CROSS_COMPILE \
		KLIB_BUILD=$KERNEL_OUTPUT_PATH modules -j$NPROC || \
		die "build_iwlwifi: Failed make modules: $?"
	make ARCH=$arch INSTALL_MOD_PATH=$TOP/$arch -C $KERNEL_OUTPUT_PATH \
		M=$iwlwifi modules_install || \
		die "build_iwlwifi: Failed make modules_install: $?"
	popd
	CCACHE=$CCACHE_SAV
}


## build_bcmdhd
#
# Build bcmdhd for PCIe and/or SDIO support
#
build_bcmdhd() {
	declare arch=$1
	declare path=$2
	declare bus=$3
	declare chip=$4

	init_compile_flags

	declare config="CONFIG_BCMDHD=m"
	if [ $bus = "PCIE" ]; then
	    config=${config}" CONFIG_BCMDHD_PCIE=y CONFIG_BCMDHD_SDIO="
	elif  [ $bus = "SDIO" ]; then
	    config=${config}" CONFIG_BCMDHD_PCIE= CONFIG_BCMDHD_SDIO=y"
	else
	    die "build_bcmdhd: unknown bus $bus $?"
	fi
	config=${config}" CONFIG_${chip}=m"

	pushd $TOP || die "build_bcmdhd: Failed to cd to $TOP: $?"
	make $MAKEOPT_OUTPUT ARCH=$arch INSTALL_MOD_PATH=$TOP/$arch -C $KPATH \
	    M=$path clean || \
	    die "build_bcmdhd: Failed to make clean: $?"
	make $MAKEOPT_OUTPUT ARCH=$arch INSTALL_MOD_PATH=$TOP/$arch -C $KPATH \
	    M=$path $config -j$NPROC modules || \
	    die "build_bcmdhd: Failed to make modules: $?"
	make $MAKEOPT_OUTPUT ARCH=$arch INSTALL_MOD_PATH=$TOP/$arch -C $KPATH \
	    M=$path modules_install || \
	    die "build_bcmdhd: Failed to make modules_install: $?"
	popd
}

## setup_config
#
# Copy the default config file into place and run "make oldconfig"
#
setup_config() {
	declare config=$1

	pushd $KERNEL_OUTPUT_PATH || \
		die "setup_config: Cannot cd to $KERNEL_OUTPUT_PATH: $?"
	cp $config .config || \
		die "setup_config: Failed to copy $config: $?"
	add_extra_version_string .config
	popd
}


## quilt_build_kernel
#
# Create the extra version information used for quilt builds
# and build the kernel.
#
quilt_build_kernel() {
	declare arch=$1
	declare prep_callback=$2
	declare config=$3
	declare kimage=$4

	quilt_reset $prep_callback
	setup_config $config
	git_build_kernel $arch $config $kimage
}


## git_build_kernel
#
# Do just a kernel build, temporarily make .git inaccessible in order
# to block the kernel build from marking the build as "dirty"
#
git_build_kernel() {
	declare arch=$1
	declare config=$2
	declare kimage=$3

	# block kernel build from marking the build as "dirty"
	pushd $KPATH || die "git_build_kernel: Cannot cd to $KPATH: $?"
	#chmod 0 .git || die "git_build_kernel: Failed to chmod 0 .git: $?"

	build_kernel $arch $config $kimage

	#put things back the way the should be
	#chmod 775 .git || die "git_build_kernel: Failed to chmod 775 .git: $?"
	popd
}


## git_build_dtbs
#
# Build and copy device tree binaries. Make .git inaccessible in order
# to avoid access to the dirty state.
#
git_build_dtbs() {
	declare arch=$1

	pushd $KPATH || die "git_build_dtbs: Cannot cd to $KPATH: $?"
	chmod 0 .git || die "git_build_dtbs: Failed to chmod 0 .git: $?"

	make $MAKEOPT_OUTPUT ARCH=$arch dtbs || die "Failed to make dtbs: $?"

	cp -r $KERNEL_OUTPUT_PATH/arch/x86/boot/dts/*.dtb $TOP/$arch || \
		die "git_build_dtbs: Failed to copy *.dtb: $?"

	cp -r $KERNEL_OUTPUT_PATH/scripts/dtc/dtc $TOP/$arch || \
		die "git_build_dtbs: Failed to copy *.dtc: $?"

	chmod 775 .git || die "git_build_dtbs: Failed to chmod 775 .git: $?"
	popd
}


## build_kernel
#
build_kernel() {
	declare arch=$1
	declare config=$2
	declare kimage=$3
	declare recursive_dep=$KERNEL_OUTPUT_PATH/.recursive_dep.$$

	init_compile_flags
	pushd $KPATH || die "build_kernel: Failed to cd to $KPATH: $?"

	# Die if "make oldconfig" will prompt for new options
	if [ -n "$AKBUILD_CHECK_NEW_CONFIG" ]; then
		if make $MAKEOPT_OUTPUT ARCH=$arch listnewconfig | grep ^CONFIG_; then
			die "build_kernel: There are new make config options"
		fi
	fi

	# check if we have dueling config files
	if [ "$KERNEL_OUTPUT_PATH" != "$KPATH" ] && [ -f $KPATH/.config ] ; then
		die "build_kernel: You must delete $KPATH/.config before building with the -o option"
	fi

	make $MAKEOPT_OUTPUT ARCH=$arch oldconfig 2> $recursive_dep || \
		die "build_kernel: make oldconfig error: $?"

	# Fail on recursive config dependencies
	if grep -q 'recursive dependency detected!' $recursive_dep; then
		warn `cat $recursive_dep`
		rm -f $recursive_dep
		die
	fi
	rm -f $recursive_dep

	if [ -n "$AKBUILD_CHECK_CONFIG_CHANGE" ]; then
		diff_config $config
	fi

	make $MAKEOPT_OUTPUT ARCH=$arch -j $NPROC || die "build_kernel: make error: $?"
	rm -rf $TOP/$arch
	mkdir $TOP/$arch || die "build_kernel: Cannot mkdir $TOP/$arch: $?"
	make $MAKEOPT_OUTPUT ARCH=$arch INSTALL_MOD_PATH=$TOP/$arch modules_install || \
		die "build_kernel: Failed make modules_install: $?"
	cd $KERNEL_OUTPUT_PATH || \
		die "build_kernel: Failed to cd to $KERNEL_OUTPUT_PATH: $?"
	cp System.map vmlinux $kimage $TOP/$arch || \
		die "build_kernel: Failed copy of System.map, ...: $?"
	cp .config $TOP/$arch/config || \
		die "build_kernel: Failed copy of .config: $?"
	popd
}


## kernel_init
#
# Initilialize the git tree for the kernel
#
kernel_init() {
	declare torvalds_remote=${1:-false}

	pushd $TOP || die "kernel_init: Failed to cd to $TOP: $?"
	if [ -d "$KPATH/.git" ]; then
		pushd $KPATH || die "kernel_init: Failed to cd to $KPATH: $?"
		chmod 775 .git || \
			die "kernel_init: Failed to chmod 775 .git: $?"
		git am --abort || echo "no apply in progress"
		git fetch origin --tags || \
			die "kernel_init: Failed to git fetch origin: $?"
		popd

	else
		git clone http://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git $KPATH
	fi

	# If the torvalds tree is also required (for development builds)
	# then add it as a remote now
	if $torvalds_remote; then
		cd $KPATH || die "kernel_init: Failed to cd to $KPATH: $?"
		if git remote | grep torvalds > /dev/null; then
			git fetch torvalds --tags || \
			    die "kernel_init: Failed to git fetch torvalds: $?"
		else
			git remote add -f --tags torvalds http://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git || \
			    die "kernel_init: Failed to add remote torvalds: $?"
		fi
	fi 
	popd
}


## process argments
#
# Process the command line arguments and set OPT_x variables as
# appropriate for use by the caller.
#
# The following global variables may also be modified by this function:
#
#   KPATH
#   KERNEL_OUTPUT_PATH
#   MAKEOPT_OUTPUT
#
process_arguments() {
	OPT_import_only=false
	OPT_compile_only=false
	OPT_debug_only=false
	OPT_exit_only=false
	OPT_exit_code=0
	OPT_arch="DEFAULT"
	OPT_kernel_output=

	if [ -z "$OPTION_STRING" ]; then
		warn "process_arguments: The OPTION_STRING variable must be" 
		die  "set by callers to the process_arguments function."
	fi

	while getopts "$OPTION_STRING" OPTION; do
		case $OPTION in
			a)
				OPT_arch=$OPTARG
				;;
			i)
				OPT_import_only=true
				;;
			c)
				OPT_compile_only=true
				;;
			d)
				OPT_debug_only=true
				;;
			o)
				OPT_kernel_output=$OPTARG
				;;
			h|?)
				OPT_exit_only=true
				;;
			esac
	done
	shift $((OPTIND-1))

	# These options are mutually exclusive
	if ( $OPT_import_only && $OPT_compile_only ) || \
	( $OPT_import_only && $OPT_debug_only ) ; then 
		OPT_exit_only=true
		OPT_exit_code=1
		return
	fi

	if [ -n "$1" ]; then
		# Force KPATH to a full-pathname
		KPATH=`readlink -f $1`
	fi

	if [ -n "$OPT_kernel_output" ]; then
		# Force KERNEL_OUTPUT_PATH to a full-pathname
		KERNEL_OUTPUT_PATH=`readlink -f $OPT_kernel_output`
		if [ "$KERNEL_OUTPUT_PATH" != "$KPATH" ]; then
			MAKEOPT_OUTPUT="O=$KERNEL_OUTPUT_PATH"
			if [ ! -d "$KERNEL_OUTPUT_PATH" ]; then
				die "No such path exists for kernel output: $KERNEL_OUTPUT_PATH"
			fi
			if [ -f $KPATH/.config ] ; then
				die "process_arguments: You must delete $KPATH/.config before building with the -o option"
			fi
		fi
	else
		KERNEL_OUTPUT_PATH=$KPATH
		MAKEOPT_OUTPUT=
	fi
}


## prepare_quilt
#
# Reset the state of the quilt tree - without applying the quilt patches
#
prepare_quilt() {
	declare prep_callback=$1

	pushd $KPATH || die "prepare_quilt: Failed to cd to $KPATH: $?"
	git reset --hard || die "prepare_quilt: Failed to git reset --hard: $?"
	git clean -xdff || die "prepare_quilt: Failed to git clean -xdff: $?"
	git checkout $KERNEL_VERSION || \
		die "prepare_quilt: Failed to git checkout $KERNEL_VERSION: $?"
	$prep_callback
	popd
}


## quilt_reset
#
# Reset the state of the quilt tree and push quilt patches
#
quilt_reset() {
	declare prep_callback=$1

	prepare_quilt $prep_callback
	pushd $KPATH || die "quilt_reset: Failed to cd to $KPATH: $?"
	quilt_push_all
	popd
}


## build_modules
#
# Receive a list of modules and build each of them
#
build_modules() {
	declare arch=$1
	shift

	init_compile_flags
	pushd $TOP || die "build_modules: Failed to cd to $TOP: $?"
	for module in $@; do
		make $MAKEOPT_OUTPUT ARCH=$arch INSTALL_MOD_PATH=$TOP/$arch -C $KPATH \
			M=$module clean || \
			die "build_modules: Failed to make clean: $?"
		make $MAKEOPT_OUTPUT ARCH=$arch INSTALL_MOD_PATH=$TOP/$arch -C $KPATH \
			M=$module -j$NPROC modules || \
			die "build_modules: Failed to make modules: $?"
		make $MAKEOPT_OUTPUT ARCH=$arch INSTALL_MOD_PATH=$TOP/$arch -C $KPATH \
			M=$module modules_install || \
			die "build_modules: Failed to make modules_install: $?"
	done
	popd
}

## build_fedcore
#
# Build fedcore module
#
build_fedcore() {
	declare arch=$1
	declare fedcore=$2
	declare install_path=$3

	init_compile_flags
	pushd $TOP || die "build_fedcore: Failed to cd to $TOP: $?"
	make $MAKEOPT_OUTPUT ARCH=$arch INSTALL_MOD_PATH=$install_path -C $KPATH \
		M=$fedcore clean || \
		die "build_fedcore: Failed to make clean: $?"
	make $MAKEOPT_OUTPUT ARCH=$arch INSTALL_MOD_PATH=$install_path -C $KPATH \
		M=$fedcore -j$NPROC modules || \
		die "build_fedcore: Failed to make fedcore: $?"
	make $MAKEOPT_OUTPUT ARCH=$arch INSTALL_MOD_PATH=$install_path -C $KPATH \
		M=$fedcore modules_install || \
		die "build_modules: Failed to make_install fedcore: $?"
	popd
}

## add_extra_version_string
#
# Modify the extra version string to include $quilt_sha1
#
add_extra_version_string() {
	declare config=$1

	#if [ ! -d $TOP/.git ]; then
		return;
	#fi

	dessert_ver=`cat $TOP/DESSERT_VERSION`
	if [ -z "$dessert_ver" ] || [ ${#dessert_ver} -ne 2 ]; then
		die "Invalid DESSERT_VERSION: $dessert_ver";
	fi

	declare quilt_sha1=$(cd $TOP; git log --pretty=format:%h -n1 --abbrev=8)
	if [ -n "$RELEASE_BUILD_NUMBER" ] ; then
		sed -i -e "/^CONFIG_LOCALVERSION/ s/CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION=\"-quilt-R$RELEASE_BUILD_NUMBER-$dessert_ver-$quilt_sha1\"/ " $config
	elif [ -n "$STAGING_BUILD_NUMBER" ] ; then
		sed -i -e "/^CONFIG_LOCALVERSION/ s/CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION=\"-quilt-S$STAGING_BUILD_NUMBER-$dessert_ver-$quilt_sha1\"/ " $config
	else
		sed -i -e "/^CONFIG_LOCALVERSION/ s/CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION=\"-quilt-$dessert_ver-$quilt_sha1\"/ " $config
	fi
}


## collect_modules
#
# Do some cleanup and perform legacy android module handling
#
collect_modules() {
	declare arch=$1

	pushd $TOP/$arch || \
		die "collect_modules: Failed to cd to $TOP/$arch: $?"
	#clean up symbolic links from the lib/module directory
	rm -f lib/modules/*/build
	rm -f lib/modules/*/source

	# legacy android module handling
	cp -a lib/modules modules || \
		die "collect_modules: Failed copy of modules: $?"
	pushd modules || die "collect_modules: Failed to cd to modules: $?"
	find . -name *.ko -print0 | xargs -0 -n1 ln -s || die "collect_modules: Failed to create a link for a kernel module! Module built both external and in-tree?" \;
	find . -name modules.*  -exec ln -s "{}"  \;
	popd

	popd
}


## diffconfig
#
# Show the configuration differences between the master copy of the
# config file and the newer version created by "make oldconfig". It
# is probably fine if the "is not set" lines are inconsistent, but
# any differences that include "=y" or "=m" settings should probably
# be sync'd up.
#
diff_config() {
	declare config=$1

	echo "Checking config: $config"
	if diff --old-line-format='OLD: %l
' --new-line-format='NEW: %l
' --unchanged-line-format='' $config $KERNEL_OUTPUT_PATH/.config | \
	grep -v CONFIG_LOCALVERSION; then
		declare localver=` grep '^CONFIG_LOCALVERSION=' $config`
		# Capture baseline LOCALVERSION
		if [ -z "$localver" ]; then
			die diff_config: Failed to extract \
				CONFIG_LOCALVERSION from $config
		fi
		# Copy new config file over
		cp $KERNEL_OUTPUT_PATH/.config $config || \
			die "diff_config: Failed to refresh config"
		# Restore LOCALVERSION
		sed -i -e "/^CONFIG_LOCALVERSION/ s/CONFIG_LOCALVERSION=.*/$localver/ " $config
		git diff $config
		die "Please commit changes to $config"
	fi
}


## make_mrproper
#
make_mrproper() {
	pushd $KPATH || die "make_mrproper: Failed cd to $KPATH: $?"
	make mrproper || die "make_mrproper: Failed make mrproper: $?"
	popd
}


## technical_debt
#
# Run akgroup to capture a representation of the technical debt
# associated with the current quilt. This functionality is enabled
# by setting the AKBUILD_TECH_DEBT_REPORT environment variable to
# contain a string with length>0.
#
technical_debt() {
	declare arch=$1
	if [ -n "$AKBUILD_TECH_DEBT_REPORT" ]; then
		$TOP/bin/akgroup -c -d $KPATH/patches > $TOP/$arch/tech-debt.csv
	fi;
}
