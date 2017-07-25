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
from .bootconf import *
import re
import os
import shutil
import string
import time

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

        # Unpack the rootfs
        if not self.fetcher.unpackRootfs(self.tempRootMountpoint):
            return False

        # Unpack the rootfs quirks
        if not self.fetcher.unpackQuirks(self.tempRootMountpoint):
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
            if not safeCopy(src_full_path, self.tempRootMountpoint + dst):
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

        # Read the list of 'to be ignored' files in boot partition and test that we have
        # something to ignore
        ignore_files = getConfigurationItem(self.conf, "FingerPrintScanner", "boot_whitelist")
        if not ignore_files:
            log.warn("updateBoot: No files configured to be ignored.")
            return True
        ignore_files = ignore_files.split()

        # Make sure boot is mounted and RW
        bootmountpoint = getBootPartitionRwMount(self.conf, self.tempBootMountpoint)
        if not bootmountpoint:
            return False

        for bootfile in bootfiles:
            # Ignore?
            if bootfile in ignore_files:
                log.warn(bootfile + " was ignored due to ignore_files configuration.")
                continue
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

    def updateSupervisorConf(self):
        """Updating the supervisor.conf on the target rootfs, so after reboot it
        will have the correct values. The relevant variables are pulled in from
        the configuration.
        """
        log.info("Started to upgrade supervisor conf...")
        supervisor_image = getConfigurationItem(self.conf, 'Supervisor', 'supervisor_image')
        supervisor_tag = getConfigurationItem(self.conf, 'Supervisor', 'supervisor_tag')
        if (not supervisor_image) or (not supervisor_tag):
            log.debug('No supervisor conf is performed as no supervisor info is passed.')
        else:
            supervisorConf = os.path.join(self.tempRootMountpoint, 'etc/supervisor.conf')
            tmpSupervisorConf = "/tmp/supervisor.conf"
            try:
                with open(tmpSupervisorConf, "w") as tmpfile:
                    with open(supervisorConf, "r") as supervisorconffile:
                        for line in supervisorconffile:
                            # Write out the lines if not one of those that
                            # we want to replace
                            if not (re.match("^SUPERVISOR_IMAGE=.*$", line) or
                                    re.match("^SUPERVISOR_TAG=.*$", line)):
                                print(line, end='', file=tmpfile)
                    # Add new values into the config file
                    log.debug("Adding: SUPERVISOR_IMAGE=" + supervisor_image)
                    print("SUPERVISOR_IMAGE={}".format(supervisor_image), file=tmpfile)
                    log.debug("Adding: SUPERVISOR_TAG=" + supervisor_tag)
                    print("SUPERVISOR_TAG={}".format(supervisor_tag), file=tmpfile)
                if  not safeCopy(tmpSupervisorConf, supervisorConf):
                    return False
                log.debug("Copied " + supervisorConf)
                os.remove(tmpSupervisorConf)
            except Exception as s:
                log.warning("Can't update " + supervisorConf)
                log.warning(str(s))
                return False
        return True

    def fixOldConfigJson(self):
        # Get host OS root mountpoint
        root_mount = getConfigurationItem(self.conf, 'General', 'host_bind_mount')
        if not root_mount:
            root_mount = '/'
        # Make sure boot is mounted and RW
        bootmountpoint = getBootPartitionRwMount(self.conf, self.tempBootMountpoint)
        if not bootmountpoint:
            return False

        # Config should be in on boot partition
        if not os.path.isfile(os.path.join(bootmountpoint, 'config.json')):
            if os.path.isfile(os.path.join(root_mount, "mnt/data-disk/config.json")) and os.path.isfile(os.path.join(root_mount, "etc/resin.conf")):
                # We are in the case were we used to have config.json in data partition
                # We need to translate resin.conf into a config.json and put the final one
                # in boot partition
                log.info("Migrate/fix config.json from data partition...")

                variablesmap = {
                    'API_ENDPOINT': 'apiEndpoint',
                    'REGISTRY_ENDPOINT': 'registryEndpoint',
                    'PUBNUB_SUBSCRIBE_KEY': 'pubnubSubscribeKey',
                    'PUBNUB_PUBLISH_KEY': 'pubnubPublishKey',
                    'MIXPANEL_TOKEN': 'mixpanelToken',
                    'LISTEN_PORT': 'listenPort'
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
                        jsonSetAttribute(tmpconfig, mappedvariable, value.strip(), onlyIfNotDefined=True)

                # Handle VPN address separately as we didn't have it in resin.conf
                # Compute vpn endpoint based on registry endpoint and write it to json
                registryEndpoint = jsonGetAttribute(tmpconfig, 'registryEndpoint')
                vpnEndpoint = registryEndpoint.strip().replace('registry', 'vpn')
                jsonSetAttribute(tmpconfig, 'vpnEndpoint', vpnEndpoint, onlyIfNotDefined=True)

                # Copy the temp config.json to resin-boot
                if not safeCopy(tmpconfig, os.path.join(bootmountpoint, 'config.json')):
                    return False
                os.remove(tmpconfig)
            elif os.path.isfile(os.path.join(root_mount, "mnt/conf/config.json")):
                # We are in the case where the config.json was in conf partition
                log.info("Migrate config.json from conf partition...")
                if not safeCopy(getConfJsonPath(self.conf), os.path.join(bootmountpoint, 'config.json')):
                    return False
            else:
                log.warn("Can't detect old config.json.")
                return False
        else:
            log.info("No need to migrate/fix config.json...")

        return True

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
        if not self.fixOldConfigJson():
            return False

        # resin-data
        if not getDevice("resin-data"):
            log.error("Can't label btrfs partition. You need to do it manually on host OS with: btrfs filesystem label <X> resin-data .")
            return False
            #btrfspartition = getBTRFSPartition(self.conf)
            #if not btrfspartition:
            #    return False
            #if not setBTRFSDeviceLabel(btrfspartition, "resin-data"):
            #    return False

        return True

    def verifyConfigJson(self):
        log.info("verifyConfigJson: Verifying and fixing config.json")
        ctype = getConfigurationItem(self.conf, 'config.json', 'type')
        if not ctype:
            log.error("Don't know if staging/production.")
            return False
        try:
            options = getSectionOptions(self.conf, ctype)
            configjsonpath = getConfJsonPath(self.conf)
            for option in options:
                value = getConfigurationItem(self.conf, ctype, option)
                if value:
                    if jsonGetAttribute(configjsonpath, option) != value:
                        log.debug("verifyConfigJson: Fixing config.json: " + option + "=" + value + ".")
                        jsonSetAttribute(configjsonpath, option, value)
                else:
                    if not jsonAttributeExists(configjsonpath, option):
                        if option == 'registered_at':
                            value = str(int(time.time()))
                        else:
                            log.error("verifyConfigJson: Don't know the value of %s." % option)
                            return False
                        log.debug("verifyConfigJson: Fixing config.json: " + option + "=" + value + ".")
                        jsonSetAttribute(configjsonpath, option, value)
        except Exception as e:
            log.error("verifyConfigJson: Error while verifying config.json.")
            log.error(str(e))
            return False
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
        if not self.verifyConfigJson():
            log.error("Could not verify config.json.")
            return False
        if not configureBootloader(getRootPartition(self.conf), self.toUpdateRootDevice()[0], self.conf):
            log.error("Could not configure bootloader.")
            return False
        if not self.updateSupervisorConf():
            log.error("Could not update supervisor config.")
            return False
        log.info("Finished to upgrade system.")
        return True

    def cleanup(self):
        log.info("Cleanup updater...")
        if isMounted(self.tempRootMountpoint):
            umount(self.tempRootMountpoint)
        mount(what='', where=getBootPartition(self.conf), mounttype='', mountoptions='remount,ro')
