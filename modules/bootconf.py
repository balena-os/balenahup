#!/usr/bin/env python3

#
# ** License **
#
# Home: http://resin.io
#
# Author: Andrei Gherzan <andrei@resin.io>
#

import logging
import tempfile
import os
from .util import *

def configureBootloader(old, new, conffile):
    ''' Configure bootloader to use the updated rootfs '''
    currentDevice = runningDevice(conffile)
    if currentDevice in ['raspberry-pi', 'raspberry-pi2', 'raspberrypi3']:
        b = BCMRasberryPiBootloader(conffile)
        if not b.configure(old, new):
            log.error("Could not configure bootloader.")
            return False
    elif currentDevice == 'intel-nuc':
        b = GrubNucBootloader(conffile)
        if not b.configure(old, new):
            log.error("Could not configure bootloader.")
            return False
    elif currentDevice == 'beaglebone-black':
        b = UBootBeagleboneBootloader(conffile)
        if not b.configure(old, new):
            log.error("Could not configure bootloader.")
            return False
    else:
        log.error("No bootloader configuration support for this board.")
        return False
    return True

class BootloaderConfigurator(object):
    def __init__ (self, conf):
        self.conf = conf

    def applyTextTransformation(self, configurationFile, old, new):
        log.debug("applyTextTransformation: Apply text replace from " + old + " to " + new + " .")

        if not os.path.isfile(configurationFile):
            log.error("applyTextTransformation: configurationFile %s doesn't exist." % configurationFile)
            return False
        lines = []
        with open(configurationFile) as infile:
            for line in infile:
                line = line.replace(old, new)
                lines.append(line)
        with open(configurationFile + ".tmp", 'w') as outfile:
            for line in lines:
                outfile.write(line)
            os.fsync(outfile)
        os.rename(configurationFile + ".tmp", configurationFile)

        # Make sure the write operation is durable - avoid data loss
        dirfd = os.open(os.path.dirname(configurationFile), os.O_DIRECTORY)
        os.fsync(dirfd)
        os.close(dirfd)

        return True

    def configure(self, old, new):
        log.info("Configuring bootloader. From " + old + " to " + new + " .")

class BCMRasberryPiBootloader(BootloaderConfigurator):
    def configure(self, old, new):
        super(BCMRasberryPiBootloader, self).configure(old, new)

        # Make sure the boot partition device is mounted
        bootdevice = getBootPartition(self.conf)
        if not isMounted(bootdevice):
            try:
                resinBootMountPoint = tempfile.mkdtemp(prefix='resinhup-', dir='/tmp')
            except:
                log.error("BCMRasberryPiBootloader: Failed to create temporary resin-boot mountpoint.")
                return False
            if not mount(what=bootdevice, where=resinBootMountPoint):
                return False
        else:
            resinBootMountPoint = getMountpoint(bootdevice)

        # We need to make sure the boot partition mountpoint is rw
        if not os.access(resinBootMountPoint, os.W_OK | os.R_OK):
            if not mount(what='', where=resinBootMountPoint, mounttype='', mountoptions='remount,rw'):
                return False
            # It *should* be fine now
            if not os.access(resinBootMountPoint, os.W_OK | os.R_OK):
                return False

        # Do the actual configuration
        if super(BCMRasberryPiBootloader, self).applyTextTransformation(resinBootMountPoint + '/cmdline.txt', old, new):
            log.info("BCM Raspberrypi Bootloader configured.")
        else:
            log.error("Could not configure BCM Raspberrypi Bootloader.")
            return False

        return True

class GrubNucBootloader(BootloaderConfigurator):
    def configure(self, old, new):
        super(GrubNucBootloader, self).configure(old, new)

        # Make sure the boot partition device is mounted
        bootdevice = getBootPartition(self.conf)
        if not isMounted(bootdevice):
            try:
                resinBootMountPoint = tempfile.mkdtemp(prefix='resinhup-', dir='/tmp')
            except:
                log.error("GrubNucBootloader: Failed to create temporary resin-boot mountpoint.")
                return False
            if not mount(what=bootdevice, where=resinBootMountPoint):
                return False
        else:
            resinBootMountPoint = getMountpoint(bootdevice)

        # We need to make sure the boot partition mountpoint is rw
        if not os.access(resinBootMountPoint, os.W_OK | os.R_OK):
            if not mount(what='', where=resinBootMountPoint, mounttype='', mountoptions='remount,rw'):
                return False
            # It *should* be fine now
            if not os.access(resinBootMountPoint, os.W_OK | os.R_OK):
                return False

        # Do the actual configuration
        if super(GrubNucBootloader, self).applyTextTransformation(resinBootMountPoint + '/EFI/BOOT/grub.cfg', old, new):
            log.info("GrubNucBootloader: GRUB Intel NUC Bootloader configured.")
        else:
            log.error("GrubNucBootloader: Could not configure GRUB Intel NUC Bootloader.")
            return False

        return True

class UBootBeagleboneBootloader(BootloaderConfigurator):

    def switchUEnv(self, old, new, uEnvPath):
        ''' Switch bootpart uboot variable using uEnv.txt - this variable points to the
            rootfs partition where the kernel is installed as well it is used by finduuid
            to get the root kernel parameter '''
        oldidx = getPartitionIndex(old)
        newidx = getPartitionIndex(new)
        if not oldidx or not newidx:
            return False

        if not super(UBootBeagleboneBootloader, self).applyTextTransformation(uEnvPath, 'bootpart=1:' + oldidx, 'bootpart=1:' + newidx):
            return False

        return True

    def tweakUEnv(self, bootmountpoint):
        ''' Various tweaks and cleanups to uEnv.txt '''

        log.info ("tweakUEnv: Tweaking and cleaning up uEnv.txt...")

        if not isMounted(bootmountpoint):
            log.error("transformUEnv: " + bootmountpoint + " is not a mountpoint.")
            return False
        uEnvPath = os.path.join(bootmountpoint, 'uEnv.txt')
        if not os.path.isfile(uEnvPath):
            log.error("transformUEnv: uEnv.txt seem not to exist in boot partition")
            return False

        lines=[]
        fixFindUUID = True
        finduuid = 'finduuid=part uuid mmc ${bootpart} uuid\n'
        with open(uEnvPath) as f:
            for line in f:
                # Remove setemmcroot lines as current uboot is not using it anymore
                if "setemmcroot" in line:
                    continue
                # Tweak finduuid to use a configurable partition
                if line.startswith('finduuid='):
                    line = finduuid
                    fixFindUUID = False

                lines.append(line)
            # If no finduuid found append one
            if fixFindUUID:
                line.append('finduuid=part uuid mmc ${bootpart} uuid\n')
        with open(uEnvPath + ".tmp", "w") as f:
            for line in lines:
                f.write(line)
            os.fsync(f)
        os.rename(uEnvPath + ".tmp", uEnvPath)

        # Make sure the write operation is durable - avoid data loss
        dirfd = os.open(os.path.dirname(uEnvPath), os.O_DIRECTORY)
        os.fsync(dirfd)
        os.close(dirfd)

        return True

    def configure(self, old, new):
        super(UBootBeagleboneBootloader, self).configure(old, new)

        # Make sure the boot partition device is mounted
        bootdevice = getBootPartition(self.conf)
        if not isMounted(bootdevice):
            try:
                resinBootMountPoint = tempfile.mkdtemp(prefix='resinhup-', dir='/tmp')
            except:
                log.error("UBootBeagleboneBootloader: Failed to create temporary resin-boot mountpoint.")
                return False
            if not mount(what=bootdevice, where=resinBootMountPoint):
                return False
        else:
            resinBootMountPoint = getMountpoint(bootdevice)

        # We need to make sure the boot partition mountpoint is rw
        if not os.access(resinBootMountPoint, os.W_OK | os.R_OK):
            if not mount(what='', where=resinBootMountPoint, mounttype='', mountoptions='remount,rw'):
                return False
            # It *should* be fine now
            if not os.access(resinBootMountPoint, os.W_OK | os.R_OK):
                return False

        if not self.tweakUEnv(resinBootMountPoint):
            log.error("UBootBeagleboneBootloader: Can't tweak uEnv.txt .")
            return False

        # Do the actual configuration
        if self.switchUEnv(old, new, resinBootMountPoint + "/uEnv.txt"):
            log.info("UBootBeagleboneBootloader: UBoot Beaglebone Bootloader configured.")
        else:
            log.error("UBootBeagleboneBootloader: Could not configure UBoot Beaglebone Bootloader.")
            return False

        return True
