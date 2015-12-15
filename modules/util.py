#!/usr/bin/env python

#
# ** License **
#
# Home: http://resin.io
#
# Author: Andrei Gherzan <andrei@resin.io>
#

import ConfigParser
import sys
import logging
import os
import stat
from glob import glob
import subprocess
import re
import string
import hashlib

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
            log.debug("Found root device: " + dev)
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
            bootdevice = str(root) + str(int(idx) - 1)
            log.debug("Couldn't find the boot partition by label. We guessed it as " + bootdevice)
            return bootdevice
    else:
        return bootdevice
    return None

def getPartitionLabel(device):
    child = subprocess.Popen("lsblk -n -o label " + device, stdout=subprocess.PIPE, shell=True)
    label = child.communicate()[0].strip()
    if child.returncode == 0 and label != "":
        log.debug("Found label " + label + " for device " + device)
        return label
    log.debug("Could not determine the label of " + device)
    return None

def getDevice(label):
    child = subprocess.Popen("blkid -l -o device -t LABEL=\"" + label + "\"", stdout=subprocess.PIPE, shell=True)
    device = child.communicate()[0].strip()
    if child.returncode == 0 and device != "":
        log.debug("Found device " + device + " for label " + label)
        return device
    return None

def setDeviceLabel(device, label):
    log.warn("Will label " + device + " as " + label)
    if not os.path.exists(device):
        return False
    if not userConfirm("Setting label for" + device + " as " + label):
        return False
    child = subprocess.Popen("e2label " + device + " " + label, stdout=subprocess.PIPE, shell=True)
    out = child.communicate()[0].strip()
    if child.returncode == 0:
        log.warn("Labeled " + device + " as " + label)
        return True
    return False

def formatEXT3(path, label):
    log.debug("Will format " + path + " as EXT3 and set its label as " + label)
    if not os.path.exists(path):
        return False
    if not userConfirm("Formatting " + path + " as EXT3 and set its label as " + label):
        return False
    child = subprocess.Popen("mkfs.ext3 -L " + label + " " + path, stdout=subprocess.PIPE, shell=True)
    out = child.communicate()[0].strip()
    if child.returncode == 0:
        log.debug("Formatted " + path + " as EXT3")
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
    log.warn(name)
    selection = getInput("Are you sure?", ["no","yes"])
    if selection == "yes":
        return True
    return False

def isMounted(dev):
    p = subprocess.Popen(['df', '-h'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True)
    p1, err = p.communicate()
    pattern = p1

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

    log.warn("Failed to unmount " + dev)
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

    log.warn("Failed to mount " + what + " in " + where + ".")
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
    config = ConfigParser.ConfigParser()
    try:
        config.read(conffile)
    except:
        log.error("Cannot read configuration file " + conffile)
        return None
    return config.get(section, option)

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
        log.debug("Detected board: " + out.strip())
        return out.strip()

    log.warn("Failed to detect board")
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
