How to build:
-------------

1. Download and install poky toolchain to its default location (/opt/poky/1.8):

        wget http://downloads.yoctoproject.org/releases/yocto/yocto-1.8/toolchain/x86_64/poky-glibc-x86_64-core-image-sato-core2-64-toolchain-1.8.sh
        sudo ./poky-glibc-x86_64-core-image-sato-core2-64-toolchain-1.8.sh

2. Clone Cherry Trail kernel build environment and fetch kernel source as submodule:

        git clone https://github.com/CM-CHT/cherrytrail_kernel_build.git -b cm-12.1
        cd cherrytrail_kernel_build
        git submodule update --init

3. Create output directory and copy defconfig:

        mkdir out
        cp linux/arch/x86/configs/x86_64_chuwi_vi10plus_defconfig out/.config

4. Compile:

        ./cht-build.sh -c -o out

You'll find kernel bzImage and modules inside x86_64 directory and also packaged inside android-kernel-prebuilds-x86_64.tgz.
