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
    else:
        log.error("No bootloader configuration support for this board.")
        return False
    return True

class BootloaderConfigurator(object):
    def __init__ (self, conf):
        self.conf = conf

    def applyTextTransformation(self, configurationFile, old, new):
        if not os.path.isfile(configurationFile):
            log.error("applyTextTransformation: configurationFile %s doesn't exist." % configurationFile)
            return False
        lines = []
        with open(configurationFile) as infile:
            for line in infile:
                line = line.replace(old, new)
                lines.append(line)
        with open(configurationFile, 'w') as outfile:
            for line in lines:
                outfile.write(line)
        return True

    def configure(self):
        log.info("Configuring bootloader.")

class BCMRasberryPiBootloader(BootloaderConfigurator):
    def configure(self, old, new):
        super(BCMRasberryPiBootloader, self).configure()

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
        super(GrubNucBootloader, self).configure()

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
