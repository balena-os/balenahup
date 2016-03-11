#!/usr/bin/env python3

#
# ** License **
#
# Home: http://resin.io
#
# Author: Andrei Gherzan <andrei@resin.io>
#

import unittest
import os
import logging
import operator
from .util import *
from .colorlogging import *

class FingerPrintScanner(object):
    def __init__(self, root, conf, images_fingerprint_path, skipMountPoints=True):
        self.root = root
        self.skipMountPoints = skipMountPoints
        self.fingerprints = dict()
        self.conf = conf
        self.images_fingerprint_path = images_fingerprint_path

    def scan(self):
        log.info("FingerPrintScanner: Started to scan for fingerprints... this will take a while...")
        whitelist_fingerprints = getConfigurationItem(self.conf, "FingerPrintScanner", "whitelist").split()
        for root, dirs, files in os.walk(self.root, followlinks=False):
            if self.skipMountPoints:
                if log.getEffectiveLevel() == logging.DEBUG:
                    # Filter out from dirs the mountpoints = stay on same filesystem
                    temp_dirs = filter(lambda dir: not os.path.ismount(os.path.join(root, dir)), dirs)
                    if set(dirs) != set(temp_dirs):
                        log.debug("FingerPrintScanner: Ignored these directories as they were mountpoint: " + ', '.join(set(dirs) - set(temp_dirs)))
                    dirs[:] = temp_dirs[:]
                    # Filter out whitelist
                    temp_dirs = filter(lambda dir: not os.path.join(root, dir) in whitelist_fingerprints, dirs)
                    if set(dirs) != set(temp_dirs):
                        log.debug("FingerPrintScanner: Ignored these directories as they were whitelisted: " + ', '.join(set(dirs) - set(temp_dirs)))
                    dirs[:] = temp_dirs[:]
                else:
                    # Same as above but without debug
                    dirs[:] = filter(lambda dir: not os.path.ismount(os.path.join(root, dir)), dirs)
                    dirs[:] = filter(lambda dir: not os.path.join(root, dir) in whitelist_fingerprints, dirs)
            for filename in files:
                if os.path.islink(os.path.join(root,filename)):
                    continue
                if not os.path.isfile(os.path.join(root,filename)):
                    continue
                if os.path.join(os.path.join(root,filename)) in whitelist_fingerprints:
                    log.debug("FingerPrintScanner: Ignored " + os.path.join(root,filename) + " as it was found whitelisted.")
                    continue

                self.fingerprints[os.path.join(root, filename)] = getmd5(os.path.join(root, filename))

    def printFingerPrints(self):
        fingerprints = "# File MD5SUM\t\t\t\tFilepath\n"
        sorted_fingerprints = sorted(self.fingerprints.items(), key=operator.itemgetter(0))
        for filename, filemd5 in sorted_fingerprints:
            fingerprints += filemd5 + "\t" + filename + "\n"
        return fingerprints

    def getFingerPrints(self):
        return self.fingerprints

    def validateFingerPrints(self):
        toReturn = True

        if len(self.fingerprints) == 0:
            self.scan()

        # Compute default file for fingerprints
        defaultFingerPrintFile = getConfigurationItem(self.conf, "FingerPrintScanner", "defaultFingerPrintFile")
        root_mount = getConfigurationItem(self.conf, 'General', 'host_bind_mount')
        if not root_mount:
            root_mount = '/'
        defaultFingerPrintFile = os.path.join(root_mount, defaultFingerPrintFile)

        if defaultFingerPrintFile and os.path.isfile(defaultFingerPrintFile):
            # Host OS fingerprint present on filesystem
            with open(defaultFingerPrintFile) as infile:
                for line in infile:
                    default_filename = line.split()[1]
                    default_filemd5 = line.split()[0]
                    for filename,filemd5 in self.fingerprints.items():
                        if filename == default_filename and filemd5 != default_filemd5:
                            log.warn("Fingerprint failed for: " + filename)
                            toReturn = False
        else:
            # Host OS fingerprint not present on filesystem
            timestamp_md5 = getmd5(os.path.join(self.root, "etc/timestamp"))
            if not timestamp_md5:
                log.error("FingerPrintScanner: Current image doesn't have a " + os.path.join(self.root, "etc/timestamp")  +  " to be used at validation.")
                return False

            image_fingerprint = os.path.join(self.images_fingerprint_path, "resin-" + timestamp_md5 + ".fingerprint")
            if not os.path.isfile(image_fingerprint):
                log.error("FingerPrintScanner: No known image fingerprint for the current image.")
                return False

            with open(image_fingerprint) as infile:
                for line in infile:
                    if not line.strip():
                        continue
                    default_occurrences = line.split()[0]
                    default_seeders = line.split()[1]
                    default_filename = line.split()[3]
                    default_filemd5 = line.split()[2]
                    if default_seeders == '1':
                        log.warn("FingerPrintScanner: We cannot consider the fingerprint of " + default_filename + " as it was generated by only one device.")
                        toReturn = False
                    for filename,filemd5 in self.fingerprints.items():
                        if filename == default_filename and filemd5 != default_filemd5:
                            log.warn("FingerPrintScanner: Fingerprint failed for: " + filename)
                            toReturn = False

        return toReturn

class MyTest(unittest.TestCase):
    def testRun(self):
        # Logger
        log = logging.getLogger()
        log.setLevel(logging.DEBUG)
        ch = logging.StreamHandler()
        ch.setFormatter(ColoredFormatter(True))
        log.addHandler(ch)

        # Test that it ignores mountpoints
        mountpoint = "./fingerprint/tests/testRun/tree/dir1"
        mount(what="tmpfs", where=mountpoint, mounttype="tmpfs")

        conf = "./fingerprint/tests/testRun/resinhup.conf"
        scanner = FingerPrintScanner("./fingerprint/tests/testRun/tree", conf, "./fingerprint/tests/testRun")
        scanner.scan()

        # Cleanup mount
        umount(mountpoint)

        print scanner.printFingerPrints()

        whitelist_fingerprints = getConfigurationItem(conf, "FingerPrintScanner", "whitelist").split()
        fingerprints = scanner.getFingerPrints()

        # Check on known file
        self.assertTrue(fingerprints['./fingerprint/tests/testRun/tree/dir4/file1'] == '68b329da9893e34099c7d8ad5cb9c940')

        for filename,filemd5 in fingerprints.items():
            self.assertFalse(filename in whitelist_fingerprints)
            # Check mountpoint
            self.assertFalse(filename.startswith(mountpoint))

        self.assertTrue(scanner.validateFingerPrints())

if __name__ == '__main__':
    unittest.main()
