#!/usr/bin/env python3

#
# ** License **
#
# Home: http://resin.io
#
# Author: Andrei Gherzan <andrei@resin.io>
#

import logging
from util import *
from bootconf import *
import re
import os
import shutil
import string

class Updater:
    def __init__(self, fetcher, conf):
        self.fetcher = fetcher
        self.tempRootMountpoint = self.fetcher.workspace + "/root-tempmountpoint"
        if not os.path.isdir(self.tempRootMountpoint):
            os.makedirs(self.tempRootMountpoint)
        self.tempBootMountpoint = self.fetcher.workspace + "/boot-tempmountpoint"
        if not os.path.isdir(self.tempBootMountpoint):
            os.makedirs(self.tempBootMountpoint)
        self.conf = conf

    # The logic here is the following:
    # Check the current root partition:
    # - if current root label is resin-root then we search for resin-updt device
    #   - if resinupdt not found then we simply increase the index for current root partition and use that
    #   - if resinupdt is found we use that device
    # - if current root label is resin-updt then we search for resin-root device
    #   - if resin-root not found then we simply decrease the index for current root partition and use that
    #   - if resin-root is found we use that device
    def toUpdateRootDevice(self):
        currentRootDevice = getRootPartition(self.conf)
        currentRootLabel = getPartitionLabel(currentRootDevice)
        if currentRootLabel == "resin-root":
            updateRootDevice = getDevice("resin-updt")
            if updateRootDevice:
                log.debug("Device to be used as rootfs update: " + updateRootDevice)
                return updateRootDevice, "resin-updt"
            else:
                match = re.match(r"(.*?)(\d+$)", currentRootDevice)
                if match:
                    root = match.groups()[0]
                    idx = match.groups()[1]
                    if int(idx) > 0:
                        updateRootDevice = str(root) + str(int(idx) + 1)
                        log.warn("We didn't find resin-updt but we guessed it as " + updateRootDevice)
                        return updateRootDevice, "resin-updt"
                log.error("Bad device path")
        elif currentRootLabel == "resin-updt":
            updateRootDevice = getDevice("resin-root")
            if updateRootDevice:
                log.debug("Device to be used as rootfs update: " + updateRootDevice)
                return updateRootDevice, "resin-root"
            else:
                match = re.match(r"(.*?)(\d+$)", currentRootDevice)
                if match:
                    root = match.groups()[0]
                    idx = match.groups()[1]
                    if int(idx) > 1:
                        updateRootDevice = str(root) + str(int(idx) - 1)
                        log.warn("We didn't find resin-updt but we guessed it as " + updateRootDevice)
                        return updateRootDevice, "resin-root"
                log.error("Bad device path")

        return None

    def unpackNewRootfs(self):
        log.info("Started to prepare new rootfs... will take a while...")

        # First we need to detect what is the device that we use as the updated rootfs
        if not self.toUpdateRootDevice():
            # This means that the current device is not labeled as it should be (old hostOS)
            # We assume this is resin-root and we rerun the update root device detection
            setDeviceLabel(getRootPartition(self.conf), "resin-root")
            if not self.toUpdateRootDevice():
                log.error("Can't find the update rootfs device")
                return False
        updateDevice, updateDeviceLabel = self.toUpdateRootDevice()

        # We need to make sure this thing is not mounted - if it is just unmount it
        if isMounted(updateDevice):
            if not umount(updateDevice):
                return False

        # Format update partition and label it accoringly
        if not formatEXT3(updateDevice, updateDeviceLabel):
            log.error("Could not format " + updateDevice + " as ext3")
            return False

        # Mount the new rootfs
        if os.path.isdir(self.tempRootMountpoint):
            if isMounted(self.tempRootMountpoint):
                if not umount(self.tempRootMountpoint):
                    return False
        else:
            os.makedirs(self.tempRootMountpoint)
        if not mount(what=updateDevice, where=self.tempRootMountpoint):
            return False

        # Unpack the rootfs archive
        if not self.fetcher.unpackRootfs(self.tempRootMountpoint):
            return False
        return True

    def rootfsOverlay(self):
        log.info("Started rootfs overlay...")
        root_mount = getConfigurationItem(self.conf, 'General', 'host_bind_mount')
        if not root_mount:
            root_mount = '/'

        # Read the overlay configuration and test that we have something to overlay
        overlay = getConfigurationItem(self.conf, "rootfs", "to_keep_files")
        if not overlay:
            log.warn("Nothing configured to overlay.")
            return True
        overlay = overlay.split()

        # Perform overlay
        for oitem in overlay:
            oitem = oitem.strip()
            if not oitem or oitem.startswith("#") or oitem.startswith(";"):
                continue
            oitem = oitem.split(":") # Handle cases where we have src:dst
            src = oitem[0]
            try:
                # If we got a "src:dst" format
                dst = oitem[1]
            except:
                # We got a "src" format
                dst = src
            src_full_path = os.path.normpath(root_mount + "/" + src)
            log.debug("Will overlay " + src_full_path)
            if not os.path.exists(src_full_path):
                log.warn(src_full_path + " was not found in your current mounted rootfs. Can't overlay.")
                continue
            if os.path.isfile(src_full_path):
                # Handle file
                if not safeCopy(src_full_path, self.tempRootMountpoint + os.path.dirname(dst)):
                    return False
            elif os.path.isdir(src_full_path):
                # Handle directory
                if not safeCopy(src_full_path, self.tempRootMountpoint + dst)
                    return False
            else:
                # Don't handle something else
                log.warn (src_full_path + " is an unhandled path")
                return False
            log.debug("Overlayed " + src_full_path + " in " + self.tempRootMountpoint)
        return True

    def updateRootfs(self):
        log.info("Started to update rootfs...")
        if not self.unpackNewRootfs():
            log.error("Could not unpack new rootfs.")
            return False
        if not self.rootfsOverlay():
            log.error("Could not overlay new rootfs.")
            return False
        return True

    def updateBoot(self):
        log.info("Started to upgrade boot files...")
        bootfiles = self.fetcher.getBootFiles()

        bootdevice = getBootPartition(self.conf)

        # Make sure the temp boot directory is unmounted
        if isMounted(self.tempBootMountpoint):
            if not umount(self.tempBootMountpoint):
                return False

        # Make sure the boot partition dev is mounted
        if not isMounted(bootdevice):
            if not mount(what=bootdevice, where=self.tempBootMountpoint):
                return False

        # We need to make sure the boot partition mountpoint is rw
        bootmountpoint = getMountpoint(bootdevice)
        if not os.access(bootmountpoint, os.W_OK | os.R_OK):
            if not mount(what='', where=bootmountpoint, mounttype='', mountoptions='remount,rw'):
                return False
            # It *should* be fine now
            if not os.access(bootmountpoint, os.W_OK | os.R_OK):
                return False

        for bootfile in bootfiles:
            # All these files are relative to bootfilesdir
            src = os.path.join(self.fetcher.bootfilesdir, bootfile)
            dst = os.path.join(bootmountpoint, bootfile)
            if os.path.isfile(dst):
                if isTextFile(src) and isTextFile(dst):
                    log.warn("Test file " + bootfile + " already exists in boot partition. Will backup.")
                    try:
                        os.rename(dst, dst + ".hup.old")
                    except Exception as s:
                        log.warn("Can't backup " + dst)
                        log.warn(str(s))
                        return False
                else:
                    log.warn("Non-text file " + bootfile + " will be overwritten.")
            if not safeCopy(src, dst):
                return False
            log.debug("Copied " + src + " to " + dst)
        return True

    def fixOldConfigJson(self):
        root_mount = getConfigurationItem(self.conf, 'General', 'host_bind_mount')
        if not root_mount:
            root_mount = '/'

        if os.path.isfile(os.path.join(root_mount, "mnt/data-disk/config.json")) and os.path.isfile(os.path.join(root_mount, "etc/resin.conf")):
            # We are in the case were we used to have config.json in btrfs partition

            variablesmap = {
                'API_ENDPOINT': 'apiEndpoint',
                'REGISTRY_ENDPOINT': 'registryEndpoint',
                'PUBNUB_SUBSCRIBE_KEY': 'pubnubSubscribeKey',
                'PUBNUB_PUBLISH_KEY': 'pubnubPublishKey',
                'MIXPANEL_TOKEN': 'mixpanelToken',
                'LISTEN_PORT': 'vpnPort'
            };

            config = os.path.join(root_mount, "mnt/data-disk/config.json")
            tmpconfig = "/tmp/config.json"
            resinconf = os.path.join(root_mount, "etc/resin.conf")

            safeCopy(config, tmpconfig) # Work on a copy

            # Make sure everything in resin.conf is in json
            with open(resinconf) as resinconffile:
                for line in resinconffile:
                    variable = line.split('=')[0]
                    if not variable in variablesmap:
                        continue
                    value = line.split('=')[1]
                    mappedvariable = variablesmap[variable]
                    command = "jq '." + mappedvariable + "=\"" + value.strip() + "\"' " + tmpconfig + " > /tmp/tempconfig.json"
                    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True)
                    out, err = child.communicate()
                    safeCopy("/tmp/tempconfig.json", tmpconfig)

            # Handle VPN address separately as we didn't have it in resin.conf
            command = "jq --raw-output '.registryEndpoint' " + tmpconfig
            child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True)
            registryEndpoint, err = child.communicate()
            vpnEndpoint = registryEndpoint.strip().replace('registry','vpn')
            command = "cat " + tmpconfig + " | jq '.vpnEndpoint=\"" + vpnEndpoint + "\"' > /tmp/tempconfig.json"
            child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True)
            out, err = child.communicate()
            safeCopy("/tmp/tempconfig.json", tmpconfig)

            configPartition = getConfigPartition(self.conf)
            if not configPartition:
                return False
            if not formatVFAT(configPartition, "resin-conf"):
                return False
            if not mcopy(dev=configPartition, src=tmpconfig, dst="::/config.json"):
                return False
            os.remove(tmpconfig)
            return True
        return False

    def fixFsLabels(self):
        log.info("Fixing the labels of all the filesystems...")

        # resin-boot
        if not getDevice("resin-boot"):
            bootdevice = getBootPartition(self.conf)
            if not bootdevice:
                return False
            if not setVFATDeviceLabel(bootdevice, "resin-boot"):
                return False

        # resin-root should be already labeled in unpackNewRootfs
        if not getDevice("resin-root"):
            return False

        # resin-updt should be already labeled in unpackNewRootfs
        if not getDevice("resin-updt"):
            return False

        # resin-conf
        if not getDevice("resin-conf"):
            if not self.fixOldConfigJson():
                return False

        # resin-data
        if not getDevice("resin-data"):
            log.error("Can't label btrfs partition. You need to do it manually on host OS with: btrfs filesystem label <X> resin-data .")
            #btrfspartition = getBTRFSPartition(self.conf)
            #if not btrfspartition:
            #    return False
            #if not setBTRFSDeviceLabel(btrfspartition, "resin-data"):
            #    return False

        return True

    def upgradeSystem(self):
        log.info("Started to upgrade system.")
        if not self.updateRootfs():
            log.error("Could not update rootfs.")
            return False
        if not self.updateBoot():
            log.error("Could not update boot.")
            return False
        if not self.fixFsLabels():
            log.error("Could not fix/setup fs labels.")
            return False
        # Configure bootloader to use the updated rootfs
        if runningDevice(self.conf) == 'raspberry-pi' or runningDevice(self.conf) == 'raspberry-pi2':
            b = BCMRasberryPiBootloader(self.conf)
            if not b.configure(getRootPartition(self.conf), self.toUpdateRootDevice()[0]):
                log.error("Could not configure bootloader.")
                return False
        else:
            log.warn("No bootloader configuration support for this board.")
        log.info("Finished to upgrade system.")
        return True

    def cleanup(self):
        log.info("Cleanup updater...")
        if isMounted(self.tempRootMountpoint):
            umount(self.tempRootMountpoint)
        mount(what='', where=getBootPartition(self.conf), mounttype='', mountoptions='remount,ro')
