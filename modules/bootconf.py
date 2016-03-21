#!/usr/bin/env python3

#
# ** License **
#
# Home: http://resin.io
#
# Author: Andrei Gherzan <andrei@resin.io>
#

import logging
from .util import *

def configureBootloader(old, new, conffile):
    ''' Configure bootloader to use the updated rootfs '''
    if runningDevice(conffile) == 'raspberry-pi' or runningDevice(conffile) == 'raspberry-pi2':
        b = BCMRasberryPiBootloader(conffile)
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
        root_mount = getConfigurationItem(self.conf, 'General', 'host_bind_mount')
        if not root_mount:
            root_mount = '/'
        configurationFile = os.path.normpath(root_mount + "/" + configurationFile)
        if not os.path.isfile(configurationFile):
            return False
        mountPoint = getMountPoint(configurationFile)
        if mountHasFlag(mountPoint, 'ro'):
            if not mount(what='', where=mountPoint, mountoptions="remount,rw"):
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
        if super(BCMRasberryPiBootloader, self).applyTextTransformation('/boot/cmdline.txt', old, new):
            log.info("BCM Raspberrypi Bootloader configured.")
        else:
            log.info("Could not configure BCM Raspberrypi Bootloader.")
            return False
        return True
