# Static binaries for 1.x to 2.x upgrades

Some additional tools are required for upgrading a 1.x resinOS prior to 1.27 to 2.x. These are:

 * e2label
 * mkfs.ext4
 * resize2fs
 * tar

These binaries have been built with buildroot, which makes static builds much easier than Yocto.
The ARM binaries are soft-float ARMv6 binaries so should be capable fo running on all ARM
platforms we support.
