#!/usr/bin/env python3

#
# ** License **
#
# Home: http://resin.io
#
# Author: Andrei Gherzan <andrei@resin.io>
#

import logging
import parted
import os
import tempfile
import unittest
from .util import *
from .bootconf import *
from .colorlogging import *

class Repartitioner(object):
    def __init__ (self, conf, testMode=False):
        self.conf = conf
        self.testMode = testMode
        self.resinBootPartPath = getBootPartition(conf)
        self.currentResinRootPartPath = getRootPartition(conf)

        self.device = parted.getDevice(getRootDevice(conf))
        self.disk = parted.newDisk(self.device)

    def editPartition(self, targetPartition, deltaStart, deltaEnd, fstype, fslabel, unit='MiB', formatPartition=True):
        log.info("editPartition: Editing partition " + targetPartition.path + ". Start = Start + (" + str(deltaStart) + "). End = End + (" + str(deltaEnd) + ").")

        # Make sure that partition is not mounted
        if isMounted(targetPartition.path):
            if not umount(targetPartition.path):
                return False

        # Committing partition changes to OS needs udev running
        startUdevDaemon()

        # Calculate the new geometry
        geometry = targetPartition.geometry
        geometry.start += parted.sizeToSectors(deltaStart, unit, self.device.sectorSize)
        geometry.end += parted.sizeToSectors(deltaEnd, unit, self.device.sectorSize)

        # Destroy the partition and recreate it with the new geometry
        self.disk.deletePartition(targetPartition)
        filesystem = parted.FileSystem(type=fstype, geometry=geometry)
        partition = parted.Partition(disk=self.disk, type=parted.PARTITION_NORMAL, fs=filesystem, geometry=geometry)
        self.disk.addPartition(partition=partition, constraint=self.device.optimalAlignedConstraint)
        self.disk.commit()

        # Format filesystem
        if formatPartition:
            if fstype == 'ext3':
                if not formatEXT3(partition.path, fslabel):
                    log.error("movePartition: Could not format " + partition.path + " as ext3.")
                    return False
            elif fstype == 'fat32':
                if not formatVFAT(partition.path, fslabel):
                    log.error("movePartition: Could not format " + partition.path + " as vfat.")
                    return False
            else:
                log.error("movePartition: Format of " + fstype + " is not implemented.")
                return False

        return True

    def increaseResinBootTo(self, size, unit='MiB'):
        #
        #           +----------------------------------------+---+
        #           | Boot from resin-root                   |   |
        # +-------->+ length(resin-root)!=length(resin-updt) | E |
        #           +----------------------------------------+---+
        #
        #
        #
        #
        #
        #
        #                                                                a1 - shrink resin-updt from left
        #                                                                a2 - copy resin-root to resin-updt
        #                                                                a3 - configure bootloader to boot from resin-updt
        #            +----------------------------------------+---+      a4 - reboot system                                    +----------------------------------------+---+
        #            | Boot from resin-root                   |   |                                                            | Boot from resin-updt                   |   |
        # +--------->+ length(resin-root)==length(resin-updt) | A +-----------------------------------------------------------^+ length(resin-root)!=length(resin-updt) | C |
        #            +-----+----------------------------------+---+                                                            +------+---------------------------------+---+
        #                  ^                                                                                                          |
        #                  |                                                                                                          |
        #                  |   b1 - configure bootloader to boot from resin-root                                                      | c1 - shrink and move resin-boot
        #                  |   b2 - reboot system                                                                                     | c2 - expand resin-boot
        #                  |                                                                                                          +
        #                  |                                                                                                          V
        #            +-----+----------------------------------+---+                                                             +--------------------------+
        #            | Boot from resin-updt                   |   |                                                             |      Done                |
        # +--------->+ length(resin-root)==length(resin-updt) | B |                                                             |    resin-boot expanded   |
        #            +----------------------------------------+---+                                                             +--------------------------+
        #
        log.info("increaseResinBootTo: Increasing boot partition to " + str(size) + ".")

        resinBootPart = self.disk.getPartitionByPath(self.resinBootPartPath)
        resinRootPart = self.disk.getPartitionByPath(getPartitionRelativeToBoot(self.conf, 'resin-root', 1))  # resin-root is the first partition after resin-boot
        resinUpdtPart = self.disk.getPartitionByPath(getPartitionRelativeToBoot(self.conf, 'resin-updt', 2))  # resin-updt is the second partition after resin-boot

        # Make sure a greater size was requested
        if (size <= resinBootPart.getLength(unit)):
            log.error("increaseResinBootTo: Size needs to be greater than current size.")
            return False

        # How much we need to increase resin-boot
        deltasize = int(size) - int(resinBootPart.getLength(unit))

        # Are we there yet?
        if resinBootPart.getLength(unit) >= size:
            # State D
            log.debug("increaseResinBootTo: Size already greater than " + str(size) + unit + ".")
            return True

        if self.currentResinRootPartPath == resinRootPart.path:
            # Booted from resin-root
            if resinRootPart.getLength(unit) == resinUpdtPart.getLength(unit):
                #
                # State A
                #
                log.debug("Running transition from State A...")

                # Edit resin-updt partition
                if not self.editPartition(targetPartition=resinUpdtPart, deltaStart=(deltasize // 2), deltaEnd=0, fstype='ext3', fslabel='resin-updt', unit=unit, formatPartition=True):
                    log.error("increaseResinBootTo: Could not edit resin-updt partition.")
                    return False

                # Copy resin-root to resin-updt
                log.info("increaseResinBootTo: Copying resin-root to resin-updt. This will take a while...")
                resinRootMountPoint = getConfigurationItem(self.conf, 'General', 'host_bind_mount')
                if not resinRootMountPoint:
                    resinRootMountPoint = '/'
                try:
                    resinUpdtMountPoint = tempfile.mkdtemp(prefix='resinhup-', dir='/tmp')
                except:
                    log.error("increaseResinBootTo: Failed to create temporary mountpoint.")
                    return False
                if not mount(resinUpdtPart.path, resinUpdtMountPoint):
                    log.error("increaseResinBootTo: Failed to mount " + resinUpdtPart.path + " to " + resinUpdtMountPoint + ".")
                if not safeCopy(resinRootMountPoint, resinUpdtMountPoint, sync=False):
                    log.error("increaseResinBootTo: Failed to copy files from " + resinRootMountPoint + " to " + resinUpdtMountPoint + ".")
                    umount(resinUpdtMountPoint) # We fail anyway so don't care out return value
                    return False
                if not umount(resinUpdtMountPoint):
                    log.error("increaseResinBootTo: Failed to unmount " + resinUpdtMountPoint + ".")
                    return False

                # Configure bootloader
                if not configureBootloader(self.currentResinRootPartPath, resinUpdtPart.path, self.conf):
                    log.error("increaseResinBootTo: Could not configure bootloader.")
                    return False

                # We reboot cause this is an intermediate repartitioning step
                if not self.testMode:
                    os.system('reboot')
            else:
                #
                # State E
                #
                log.debug("Running transition from State E...")

                log.error("increaseResinBootTo: Unknown filesystem state where booted from resin-boot but having different size then resin-updt.")
                return False

        elif self.currentResinRootPartPath == resinUpdtPart.path:
            # Booted from resin-updt
            if resinRootPart.getLength(unit) == resinUpdtPart.getLength(unit):
                #
                # State B
                #
                log.debug("Running transition from State B...")

                # Configure bootloader
                if not configureBootloader(self.currentResinRootPartPath, resinRootPart.path, self.conf):
                    log.error("increaseResinBootTo: Could not configure bootloader.")
                    return False

                # We reboot cause this is an intermediate repartitioning step
                if not self.testMode:
                    os.system('reboot')
            else:
                #
                # State C
                #
                log.debug("Running transition from State C...")

                # Edit resin-root partition
                if not self.editPartition(targetPartition=resinRootPart, deltaStart=(deltasize), deltaEnd=(deltasize // 2), fstype='ext3', fslabel='resin-root', unit=unit, formatPartition=True):
                    log.error("increaseResinBootTo: Could not edit resin-root partition.")
                    return False

                # Expand resin-boot
                if not self.editPartition(targetPartition=resinBootPart, deltaStart=0, deltaEnd=deltasize, fstype='fat32', fslabel='resin-boot', unit=unit, formatPartition=False):
                    log.error("increaseResinBootTo: Could not edit resin-boot partition.")
                    return False

                return True
        else:
            log.error("increaseResinBootTo: Unknown root partition.")
            return False

        return True

class MyTest(unittest.TestCase):
    def testRun(self):
        # Logger
        log = logging.getLogger()
        log.setLevel(logging.DEBUG)
        ch = logging.StreamHandler()
        ch.setFormatter(ColoredFormatter(True))
        log.addHandler(ch)

        # Hope this works :)
        r = Repartitioner(conf='conf/resinhup.conf', testMode=True) # Running this in test mode to avoid rebooting automatically
        self.assertTrue(r.increaseResinBootTo(22))

if __name__ == '__main__':
    unittest.main()
