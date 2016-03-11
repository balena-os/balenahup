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
    for f in glob("/sys/class/block/*/dev"):
        if file(f).read().strip() == root:
            dev = "/dev/" + os.path.basename(os.path.dirname(f))
            log.debug("Found root partition: " + dev)
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


def isTextFile(filename, bs = 512):
    if not os.path.exists(filename):
        return False
    with open(filename) as f:
        block = f.read(bs)

    txtChars = "".join(map(chr, range(32, 127)) + list("\n\r\t\b"))
    _null_trans = string.maketrans("", "")

    # If it includes null char we consider it not test
    if "\0" in block:
        return False

    # Empty files are considered text
    if not block:
        return True

    nonTxtChars = block.translate(_null_trans, txtChars)

    if len(nonTxtChars)/len(block) > 0.20:
        return False

    return True

def getConfigurationItem(conffile, section, option):
    if not os.path.isfile(conffile):
        log.error("Configuration file " + conffile + " not found.")
        return None
    config = configparser.ConfigParser()
    try:
        config.read(conffile)
    except:
        log.error("Cannot read configuration file " + conffile)
        return None
    return config.get(section, option)

def getSectionOptions(conffile, section):
    if not os.path.isfile(conffile):
        log.error("Configuration file " + conffile + " not found.")
        return None
    config = configparser.ConfigParser()
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
    try:
        config.read(conffile)
        config.set(section, option, value)
        with open(conffile, 'wb') as cf:
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
    if rootpartition.startswith("sd"):
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

def jsonAttributeExists(json, attribute):
    # Load the decoded json file
    try:
        with open(json, 'r') as fd:
            configjson = json.load(fd)
    except:
        log.error("jsonSetAttribute: Can't read or decode " + json + ".")
        return False

    return attribute in configjson.keys()

def jsonSetAttribute(json, attribute, value, onlyIfNotDefined=False):
    # Load the decoded json file
    try:
        with open(json, 'r') as fd:
            configjson = json.load(fd)
    except:
        log.error("jsonSetAttribute: Can't read or decode " + json + ".")
        return False

    # Handle onlyIfNotDefined
    if attribute in configjson.keys():
        if onlyIfNotDefined:
            log.error("jsonSetAttribute: " + attribute + " already defined.")
            return False
        else:
            log.warn("jsonSetAttribute: " + attribute + " will be overwritten.")

    configjson[atttribute] = value # Set the required attribute

    # Write new json to a tmp file
    try:
        with open(json+'.hup.tmp', 'w') as fd:
            configjson = json.dump(configjson, fd)
            os.fsync(fd)
    except:
        log.error("jsonSetAttribute: Can't write or encode to " + json + ".")
        return False

    os.rename(json+'.hup.tmp', json) # Atomic rename file

    log.debug("jsonSetAttribute: Successfully set " + attribute + " to " + value + " in " + json + ".")
    return True

def safeCopy(src, dst):
    if os.path.isfile(src):
        return safeFileCopy(src, dst)
    elif os.path.isdir(src):
        return safeDirCopy(src, dst)
    else:
        log.error("Unknown src target to copy " + src + ".")
        return False

def safeDirCopy(src, dst):
    # src must be a dir
    if not os.path.isdir(src):
        log.error("Can't copy source as " + src + " is not a directory.")
        return False

    # dst must not exist
    if os.path.isdir(dst):
        log.error("Can't copy to an existent directory " + dst + " .")
        return False

    # Copy each file in the structure of src to dst
    for root, dirs, files in os.walk(src):
            for name in files:
                srcfullpath = os.path.join(root, name)
                dstfullpath = os.path.join(dst, os.path.relpath(srcfullpath, src))
                print(srcfullpath + " -> " + dstfullpath)
                if not safeFileCopy(srcfullpath, dstfullpath):
                    return False
    return True

def safeFileCopy(src, dst):
    # src must be a file
    if not os.path.isfile(src):
        log.error("safeFileCopy: Can't copy source as " + src + " is not a file.")
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
    with open(src, 'rb') as srcfd, open(dst + ".tmp", "wb") as dsttmpfd:
        try:
            shutil.copyfileobj(srcfd, dsttmpfd)
        except:
            log.error("safeFileCopy: Failed to copy " + src + ".")
            return False
        os.fsync(dsttmpfd)

    # Rename and sync filesystem to disk
    os.rename(dst + ".tmp", dst)
    os.sync()

    return True

class TestSafeFileCopy(unittest.TestCase):
    def testSafeFileCopyNormal(self):
        src = "./util/safefilecopy/file1"
        dst = "./util/safefilecopy/file1.test"
        self.assertTrue(safeFileCopy(src, dst))
        os.remove(dst) # cleanup

    def testSafeFileCopySrcInvalid(self):
        src = "./util/safefilecopy/none"
        dst = "./util/safefilecopy/file1.test"
        self.assertFalse(safeFileCopy(src, dst))

    def testSafeFileCopyOverwrite(self):
        src = "./util/safefilecopy/file1"
        dst = "./util/safefilecopy/file2"
        with open(dst,'w') as f:
            f.write("file2")
        self.assertTrue(safeFileCopy(src, dst))
        with open(dst,'r') as f:
            content = f.read()
        self.assertTrue(content == 'file1')
        os.remove(dst) # cleanup

    def testSafeFileCopySrcDir(self):
        src = "./util/safefilecopy/dir1"
        dst = "./util/safefilecopy/file2"
        self.assertFalse(safeFileCopy(src, dst))

    def testSafeFileCopyDstDir(self):
        src = "./util/safefilecopy/file1"
        dst = "./util/safefilecopy/dir1"
        self.assertFalse(safeFileCopy(src, dst))

    def testSafeFileCopyToDirStr(self):
        src = "./util/safefilecopy/dir1/file2"
        dst = "./util/safefilecopy/dir2/dir3/file4"
        self.assertTrue(safeFileCopy(src, dst))
        self.assertTrue(os.path.isfile(dst))
        with open(dst,'r') as f:
            content = f.read()
        self.assertTrue(content == 'file2')
        shutil.rmtree("./util/safefilecopy/dir2") # cleanup

class TestSafeDirCopy(unittest.TestCase):
    def testSafeDirCopyNormal(self):
        src = "./util/safedircopy/dir1"
        dst = "./util/safedircopy/dir3"
        self.assertTrue(safeDirCopy(src, dst))
        shutil.rmtree(dst) # cleanup

    def testSafeDirCopyDstExistent(self):
        src = "./util/safedircopy/dir1"
        dst = "./util/safedircopy/dir1"
        self.assertFalse(safeDirCopy(src, dst))

    def testSafeDirCopyFile(self):
        src = "./util/safedircopy/dir1/file2"
        dst = "./util/safedircopy/dir3"
        self.assertFalse(safeDirCopy(src, dst))

if __name__ == '__main__':
    unittest.main()
