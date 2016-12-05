#!/usr/bin/env python3

#
# ** License **
#
# Home: http://resin.io
#
# Author: Andrei Gherzan <andrei@resin.io>
#

import configparser
import sys
import logging
import os
import stat
from glob import glob
import subprocess
import re
import string
import hashlib
import unittest
import shutil
import json
from binaryornot.check import is_binary

log = logging.getLogger(__name__)

def check_if_root():
    if os.geteuid() == 0:
        return True
    else:
        return False

def getRootPartition(conffile):
    root_mount = getConfigurationItem(conffile, 'General', 'host_bind_mount')
    if not root_mount:
        root_mount = '/'
    rootdev = os.stat(root_mount)[stat.ST_DEV]
    rootmajor=os.major(rootdev)
    rootminor=os.minor(rootdev)
    root="%d:%d" % (rootmajor, rootminor)
    for filepath in glob("/sys/class/block/*/dev"):
        with open(filepath) as fd:
            if fd.read().strip() == root:
                dev = "/dev/" + os.path.basename(os.path.dirname(filepath))
                log.debug("Found root partition: " + dev + ".")
                return dev
    return None

def getBootPartition(conffile):
    # First search by label
    bootdevice = getDevice("resin-boot")
    if not bootdevice:
        # The bootdevice is the first partition on the same device with the root device
        match = re.match(r"(.*?)(\d+$)", getRootPartition(conffile))
        if match:
            root = match.groups()[0]
            idx = 1 # TODO boot partition is always the first one ??? is it?
            bootdevice = str(root) + str(int(idx))
            log.debug("Couldn't find the boot partition by label. We guessed it as " + bootdevice)
            return bootdevice
    else:
        return bootdevice
    return None

def getBootPartitionRwMount(conffile, where):
    'Returns the mount location of the boot partition while making sure it is mounted rw'
    bootdevice = getBootPartition(conffile)
    if not isMounted(bootdevice):
        if isMounted(where):
            if not umount(where):
                return None
        if not mount(what=bootdevice, where=where):
            return None

    bootmountpoint = getMountpoint(bootdevice)
    if not os.access(bootmountpoint, os.W_OK | os.R_OK):
        if not mount(what='', where=bootmountpoint, mounttype='', mountoptions='remount,rw'):
            return None
        # It *should* be fine now
        if not os.access(bootmountpoint, os.W_OK | os.R_OK):
            return None
    return bootmountpoint

def getPartitionIndex(device):
    ''' Get the index number of a partition '''
    match = re.match(r"(.*?)(\d+$)", device)
    if match:
        return match.groups()[1]

def getPartitionRelativeToBoot(conffile, label, relativeIndex):
    ''' Returns the partition device path when index is relative to boot partition '''
    # First search by label
    partdevice = getDevice(label)
    if not partdevice:
        match = re.match(r"(.*?)(\d+$)", getBootPartition(conffile))
        if match:
            root = match.groups()[0]
            idx = match.groups()[1]
            partdevice = str(root) + str(int(idx) + int(relativeIndex))
            log.debug("Couldn't find the %s partition by label. We guessed it as being %s." %(label, partdevice))
            return partdevice
    else:
        return partdevice
    return None

def getPartitionLabel(device):
    child = subprocess.Popen("lsblk -n -o label " + device, stdout=subprocess.PIPE, shell=True)
    label = child.communicate()[0].decode().strip()
    if child.returncode == 0 and label != "":
        log.debug("Found label " + label + " for device " + device)
        return label
    log.debug("Could not determine the label of " + device)
    return None

def getDevice(label):
    child = subprocess.Popen("blkid -l -o device -t LABEL=\"" + label + "\"", stdout=subprocess.PIPE, shell=True)
    device = child.communicate()[0].decode().strip()
    if child.returncode == 0 and device != "":
        log.debug("Found device " + device + " for label " + label)
        return device
    return None

def setDeviceLabel(device, label):
    log.warning("Will label " + device + " as " + label)
    if not os.path.exists(device):
        return False
    if not userConfirm("Setting label for " + device + " as " + label):
        return False
    child = subprocess.Popen("e2label " + device + " " + label, stdout=subprocess.PIPE, shell=True)
    out = child.communicate()[0].decode().strip()
    if child.returncode == 0:
        log.warning("Labeled " + device + " as " + label)
        return True
    return False

def setVFATDeviceLabel(device, label):
    log.warning("Will label " + device + " as " + label)
    if not os.path.exists(device):
        return False
    if not userConfirm("Setting label for " + device + " as " + label):
        return False
    child = subprocess.Popen("dosfslabel " + device + " " + label, stdout=subprocess.PIPE, shell=True)
    out = child.communicate()[0].decode().strip()
    if child.returncode == 0:
        log.warning("Labeled " + device + " as " + label)
        return True
    return False

def setBTRFSDeviceLabel(device, label):
    log.warning("Will label " + device + " as " + label)
    if not os.path.exists(device):
        return False

    # If mounted we need to specify the mountpoint in btrfs command
    if isMounted(device):
        device = getMountpoint(device)
        if not device:
            return False

    if not userConfirm("Setting label for " + device + " as " + label):
        return False
    child = subprocess.Popen("btrfs filesystem label " + device + " " + label, stdout=subprocess.PIPE, shell=True)
    out = child.communicate()[0].decode().strip()
    if child.returncode == 0:
        log.warning("Labeled " + device + " as " + label)
        return True
    return False

def formatEXT3(path, label):
    log.debug("Will format " + path + " as EXT3 and set its label as " + label)
    if not os.path.exists(path):
        return False
    if not userConfirm("Formatting " + path + " as EXT3 and set its label as " + label):
        return False
    child = subprocess.Popen("mkfs.ext3 -L " + label + " " + path, stdout=subprocess.PIPE, shell=True)
    out = child.communicate()[0].decode().strip()
    if child.returncode == 0:
        log.debug("Formatted " + path + " as EXT3")
        return True
    return False

def formatVFAT(path, label):
    log.debug("Will format " + path + " as VFAT and set its label as " + label)
    if not os.path.exists(path):
        return False
    if not userConfirm("Formatting " + path + " as VFAT and set its label as " + label):
        return False
    child = subprocess.Popen("mkfs.vfat -n " + label + " -S 512 " + path, stdout=subprocess.PIPE, shell=True)
    out = child.communicate()[0].decode().strip()
    if child.returncode == 0:
        log.debug("Formatted " + path + " as VFAT")
        return True
    return False

def getInput(helpmsg, valids = []):
    if not valids:
        return
    sys.stdout.write(helpmsg + " [" + '|'.join(valids)  + "]: ")
    s = raw_input()
    while not s in valids:
        s = raw_input("Wrong selection [" + '|'.join(valids)  + "]: ")
    return s

def userConfirm(name):
    log.warning(name)
    return True # No interactive mode anymore
    selection = getInput("Are you sure?", ["no","yes"])
    if selection == "yes":
        return True
    return False

def isMounted(dev):
    p = subprocess.Popen(['df', '-h'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True)
    p1, err = p.communicate()
    pattern = p1.decode()

    if pattern.find(dev) == -1:
        log.debug(dev + " is not mounted")
        return False

    log.debug(dev + " is mounted")
    return True

def umount(dev):
    child = subprocess.Popen("umount " + dev, stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True)
    out, err = child.communicate()
    if child.returncode == 0:
        log.debug("Unmounted " + dev)
        return True

    log.warning("Failed to unmount " + dev)
    return False

def mount(what, where, mounttype='', mountoptions=''):
    if mounttype:
        mounttype = "-t " + mounttype
    if mountoptions:
        mountoptions = "-o " + mountoptions
    cmd = "mount " + mounttype + " " + mountoptions + " " + what + " " + where
    child = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True)
    out, err = child.communicate()
    if child.returncode == 0:
        log.debug("Mounted " + what + " in " + where + ".")
        return True

    log.warning("Failed to mount " + what + " in " + where + ".")
    return False

def getMountpoint(dev):
    if os.path.isfile("/proc/mounts"):
        with open('/proc/mounts', 'r') as f:
            mounts = f.readlines()
            for mount in mounts:
                tokens = mount.split()
                if tokens[0] == dev:
                    log.debug("Found mountpoint of " + dev + " as " + tokens[1])
                    return tokens[1]
    return None


def isTextFile(filename):
    return (not is_binary(filename))

def getConfigurationItem(conffile, section, option):
    if not os.path.isfile(conffile):
        log.error("Configuration file " + conffile + " not found.")
        return None
    config = configparser.ConfigParser()
    config.optionxform=str
    try:
        config.read(conffile)
        return config.get(section, option)
    except:
        log.warning("Cannot get from configuration file " + conffile + ", section " + section + ", option " + option + ".")
        return None

def getSectionOptions(conffile, section):
    if not os.path.isfile(conffile):
        log.error("Configuration file " + conffile + " not found.")
        return None
    config = configparser.ConfigParser()
    config.optionxform=str
    try:
        config.read(conffile)
    except:
        log.error("Cannot read configuration file " + conffile)
        return None
    return config.options(section)

def setConfigurationItem(conffile, section, option, value):
    if not os.path.isfile(conffile):
        log.error("Configuration file " + conffile + " not found.")
        return None
    config = configparser.ConfigParser()
    config.optionxform=str
    try:
        config.read(conffile)
        config.set(section, option, value)
        with open(conffile, 'w') as cf:
            config.write(cf)
    except:
        log.error("Cannot set required configuration value in " + conffile)
        return False
    return True

def getConfJsonPath(conffile):
    root_mount = getConfigurationItem(conffile, 'General', 'host_bind_mount')
    if not root_mount:
        root_mount = '/'
    possible_locations = getConfigurationItem(conffile, 'config.json', 'possible_locations')
    if not possible_locations:
        return None
    possible_locations = possible_locations.split()

    # config.json should be in boot partition so let's prepend the temporary mountpoint
    # for this partition
    fetcher_workspace = getConfigurationItem(conffile, 'fetcher', 'workspace')
    tempbootmountpoint = os.path.join(fetcher_workspace, 'boot-tempmountpoint')
    possible_locations.insert(0, tempbootmountpoint)

    for location in possible_locations:
        if os.path.isfile(os.path.normpath(root_mount + "/" + location + '/config.json')):
            log.debug("Detected config.json in " + location)
            return os.path.normpath(root_mount + "/" + location + '/config.json')
    return None

def runningDevice(conffile):
    conf = getConfJsonPath(conffile)
    if not conf:
        return None
    child = subprocess.Popen("jq -r .deviceType " + conf, stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True)
    out, err = child.communicate()
    if out:
        log.debug("Detected board: " + out.decode().strip())
        return out.decode().strip()

    log.warning("Failed to detect board")
    return None

def getMountPoint(path):
    path = os.path.abspath(path)
    while not os.path.ismount(path):
        path = os.path.dirname(path)
    return path

def mountHasFlag(path, flag):
    with open('/proc/mounts') as f:
        for line in f:
            device, mount_point, filesystem, flags, __, __ = line.split()
            flags = flags.split(',')
            if mount_point == path:
                return flag in flags
    return False

# Compute the md5 of a file
def getmd5(inputfile, blocksize=4096):
    if not os.path.isfile(inputfile):
        return None
    hash = hashlib.md5()
    with open(inputfile, "rb") as f:
        for block in iter(lambda: f.read(blocksize), b""):
            hash.update(block)
    return hash.hexdigest()

def getRootDevice(conffile):
    rootpartition = getRootPartition(conffile)
    if not rootpartition:
        return None
    if rootpartition.startswith("/dev/sd"):
        rootdevice = rootpartition[:-1]
    else:
        rootdevice = rootpartition[:-2]
    log.debug("Found root device: " + rootdevice + ".")
    return rootdevice

def getExtendedPartition(conffile):
    rootdevice = getRootDevice(conffile)
    if not rootdevice:
        return None
    child = subprocess.Popen("fdisk -l | grep \"Ext'd\" | awk '{print $1}' | grep " + rootdevice , stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True)
    out, err = child.communicate()
    if out:
        log.debug("Detected extended partition: " + out.decode().strip())
        return out.decode().strip()
    return None

def getConfigPartition(conffile):
    # Extended +1
    extendedPartition = getExtendedPartition(conffile)
    if not extendedPartition:
        return None
    match = re.match(r"(.*?)(\d+$)", extendedPartition)
    root = match.groups()[0]
    idx = match.groups()[1]
    return str(root) + str(int(idx) + 1)

def getBTRFSPartition(conffile):
    # Extended +2
    extendedPartition = getExtendedPartition(conffile)
    if not extendedPartition:
        return None
    match = re.match(r"(.*?)(\d+$)", extendedPartition)
    root = match.groups()[0]
    idx = match.groups()[1]
    return str(root) + str(int(idx) + 2)

def mcopy(dev, src, dst):
    child = subprocess.Popen("mcopy -i " + dev + " " + src + " " + dst , stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True)
    out, err = child.communicate()
    if child.returncode != 0:
        log.debug("Failed to mcopy in " + dev);
        return False
    return True

def get_pids(name):
    try:
        pids = subprocess.check_output(["pidof",name])
    except:
        return None
    return pids.split()

def startUdevDaemon():
    if get_pids('udevd'):
        log.debug('startUdevDaemon: udevd already running.')
        return True

    child = subprocess.Popen("udevd --daemon" , stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True)
    out, err = child.communicate()
    if child.returncode != 0:
        log.debug("Failed to start udev as daemon");
        return False
    return True

def getCurrentHostOSVersion(conffile):
    ''' Get current OS version from /etc/os-release '''
    root_mount = getConfigurationItem(conffile, 'General', 'host_bind_mount')
    if not root_mount:
        root_mount = '/'
    try:
        with open(os.path.join(root_mount, "etc/os-release"), 'r') as f:
            lines = f.readlines()
            for line in lines:
                (attribute, value) = line.split('=')
                if attribute == 'VERSION':
                    return value.strip(' "\n')
    except:
        log.debug("getCurrentHostOSVersion: Can't get the current host OS version")

def jsonDecode(jsonfile):
    try:
        with open(jsonfile, 'r') as fd:
            configjson = json.load(fd)
    except Exception as e:
        log.error("jsonDecode: Can't read or decode " + jsonfile + ".")
        log.error(str(e))
        return None
    return configjson

def jsonAttributeExists(jsonfile, attribute):
    # Decode json first
    configjson = jsonDecode(jsonfile)
    if not configjson:
        return False

    return attribute in configjson.keys()

def jsonGetAttribute(jsonfile, attribute):
    # Decode json first
    configjson = jsonDecode(jsonfile)
    if not configjson:
        return None

    if attribute in configjson.keys():
        return configjson[attribute]
    else:
        return None

def jsonSetAttribute(jsonfile, attribute, value, onlyIfNotDefined=False):
    # Decode json first
    configjson = jsonDecode(jsonfile)
    if not configjson:
        return False

    # Handle onlyIfNotDefined
    if attribute in configjson.keys():
        if onlyIfNotDefined:
            log.error("jsonSetAttribute: " + attribute + " already defined.")
            return False
        else:
            log.warn("jsonSetAttribute: " + attribute + " will be overwritten.")

    configjson[attribute] = value # Set the required attribute

    # Write new json to a tmp file
    try:
        with open(jsonfile + '.hup.tmp', 'w') as fd:
            configjson = json.dump(configjson, fd)
            os.fsync(fd)
    except:
        log.error("jsonSetAttribute: Can't write or encode to " + jsonfile + ".")
        return False

    os.rename(jsonfile + '.hup.tmp', jsonfile) # Atomic rename file

    log.debug("jsonSetAttribute: Successfully set " + attribute + " to " + value + " in " + jsonfile + ".")
    return True

def safeCopy(src, dst, sync=True, ignore=[]):
    if os.path.isfile(src) or os.path.islink(src):
        return safeFileCopy(src, dst, sync)
    elif os.path.isdir(src):
        return safeDirCopy(src, dst, sync, ignore)
    else:
        log.error("safeCopy: Unknown src target to copy " + src + ".")
        return False

def safeDirCopy(src, dst, sync=True, ignore=[]):
    # src must be a dir
    if not os.path.isdir(src):
        log.error("safeDirCopy: Can't copy source as " + src + " is not a directory.")
        return False

    # dst must not be the same as src
    if os.path.abspath(src) == os.path.abspath(dst):
        log.error("safeDirCopy: Can't copy to the same source directory " + src + " .")
        return False

    # Copy each file in the structure of src to dst
    for root, dirs, files in os.walk(src):

            # Directories
            for d in dirs:
                if d in ignore:
                    log.warning("safeDirCopy: Ignored directory " + d + ".")
                    dirs.remove(d)
                    continue
                try:
                    srcfullpath = os.path.join(root, d)
                    dstfullpath = os.path.join(dst, os.path.relpath(srcfullpath, src))
                    if os.path.islink(srcfullpath):
                        if not safeFileCopy(srcfullpath, dstfullpath, sync):
                            return False
                    else:
                        os.makedirs(dstfullpath, exist_ok=True)
                        shutil.copymode(srcfullpath, dstfullpath)
                except Exception as e:
                    log.error(str(e))
                    return False

            # Files
            for name in files:
                if name in ignore:
                    log.warning("safeDirCopy: Ignored file " + d + ".")
                    continue
                srcfullpath = os.path.join(root, name)
                dstfullpath = os.path.join(dst, os.path.relpath(srcfullpath, src))
                if stat.S_ISFIFO(os.stat(srcfullpath, follow_symlinks=False).st_mode): # FIXME Ignore pipe files
                    continue
                if not safeFileCopy(srcfullpath, dstfullpath, sync):
                    return False

            # Stay on the same filesystem
            dirs[:] = list(filter(lambda dir: not os.path.ismount(os.path.join(root, dir)), dirs))

    return True

def safeFileCopy(src, dst, sync=True):
    # src must be a file
    if (not os.path.isfile(src)) and (not os.path.islink(src)):
        log.error("safeFileCopy: Can't copy source as " + src + " is not a handled file.")
        return False

    # Make sure dst is either non-existent or a file (which we overwrite)
    if os.path.exists(dst):
        if os.path.isfile(dst):
            log.warning("safeFileCopy: Destination file " + dst + " already exists. Will overwrite.")
        elif os.path.isdir(dst):
            log.error("safeFileCopy: Destination target " + dst + " is a directory.")
            return False
        else:
            log.error("safeFileCopy: Destination target " + dst + " is unknown.")
            return False

    # Copy file to dst.tmp
    if not os.path.isdir(os.path.dirname(dst)):
        try:
            os.makedirs(os.path.dirname(dst))
        except:
            log.error("safeFileCopy: Failed to create directories structure for destination " + dst + ".")
            return False
    if os.path.islink(src):
        linkto = os.readlink(src)
        os.symlink(linkto, dst + ".tmp")
    else:
        with open(src, 'rb') as srcfd, open(dst + ".tmp", "wb") as dsttmpfd:
            try:
                shutil.copyfileobj(srcfd, dsttmpfd)
            except Exception as s:
                log.error("safeFileCopy: Failed to copy " + src + " to " + dst + ".tmp .")
                log.error(str(s))
                return False
            shutil.copymode(src, dst + ".tmp")
            if sync:
                os.fsync(dsttmpfd)

    # Rename and sync filesystem to disk
    os.rename(dst + ".tmp", dst)
    if sync:
        # # Make sure the write operation is durable - avoid data loss
        dirfd = os.open(os.path.dirname(dst), os.O_DIRECTORY)
        os.fsync(dirfd)
        os.close(dirfd)

        os.sync()

    return True

class TestSafeFileCopy(unittest.TestCase):
    def testSafeFileCopyNormal(self):
        src = "./modules/util/safefilecopy/file1"
        dst = "./modules/util/safefilecopy/file1.test"
        self.assertTrue(safeFileCopy(src, dst))
        os.remove(dst) # cleanup

    def testSafeFileCopySrcInvalid(self):
        src = "./modules/util/safefilecopy/none"
        dst = "./modules/util/safefilecopy/file1.test"
        self.assertFalse(safeFileCopy(src, dst))

    def testSafeFileCopyOverwrite(self):
        src = "./modules/util/safefilecopy/file1"
        dst = "./modules/util/safefilecopy/file2"
        with open(dst,'w') as f:
            f.write("file2")
        self.assertTrue(safeFileCopy(src, dst))
        with open(dst,'r') as f:
            content = f.read()
        self.assertTrue(content == 'file1')
        os.remove(dst) # cleanup

    def testSafeFileCopySrcDir(self):
        src = "./modules/util/safefilecopy/dir1"
        dst = "./modules/util/safefilecopy/file2"
        self.assertFalse(safeFileCopy(src, dst))

    def testSafeFileCopyDstDir(self):
        src = "./modules/util/safefilecopy/file1"
        dst = "./modules/util/safefilecopy/dir1"
        self.assertFalse(safeFileCopy(src, dst))

    def testSafeFileCopyToDirStr(self):
        src = "./modules/util/safefilecopy/dir1/file2"
        dst = "./modules/util/safefilecopy/dir2/dir3/file4"
        self.assertTrue(safeFileCopy(src, dst))
        self.assertTrue(os.path.isfile(dst))
        with open(dst,'r') as f:
            content = f.read()
        self.assertTrue(content == 'file2')
        shutil.rmtree("./modules/util/safefilecopy/dir2") # cleanup

class TestSafeDirCopy(unittest.TestCase):
    def testSafeDirCopyNormal(self):
        src = "./modules/util/safedircopy/dir1"
        dst = "./modules/util/safedircopy/dir3"
        self.assertTrue(safeDirCopy(src, dst))
        shutil.rmtree(dst) # cleanup

    def testSafeDirCopyDstExistent(self):
        src = "./modules/util/safedircopy/dir1"
        dst = "./modules/util/safedircopy/dir1"
        self.assertFalse(safeDirCopy(src, dst))

    def testSafeDirCopyFile(self):
        src = "./modules/util/safedircopy/dir1/file2"
        dst = "./modules/util/safedircopy/dir3"
        self.assertFalse(safeDirCopy(src, dst))

    def testSafeDirCopyIgnoreDir(self):
        src = "./modules/util/safedircopy/dir1"
        dst = "./modules/util/safedircopy/dir3"
        self.assertTrue(safeCopy(src, dst, ignore=['ignore-dir']))
        self.assertFalse(os.path.isdir(os.path.join(dst, "ignore-dir")))
        shutil.rmtree(dst) # cleanup

    def testSafeDirCopyIgnoreFile(self):
        src = "./modules/util/safedircopy/dir1"
        dst = "./modules/util/safedircopy/dir3"
        self.assertTrue(safeCopy(src, dst, ignore=['ignore-file']))
        self.assertFalse(os.path.isdir(os.path.join(dst, "ignore-dir/ignore-file")))
        shutil.rmtree(dst) # cleanup

if __name__ == '__main__':
    unittest.main()
