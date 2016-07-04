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
    def __init__(self, root, boot, conf, images_fingerprint_path, skipMountPoints=True):
        self.root = root
        self.boot = boot
        self.skipMountPoints = skipMountPoints
        self.root_fingerprints = dict()
        self.boot_fingerprints = dict()
        self.conf = conf
        self.images_fingerprint_path = images_fingerprint_path

    def do_scan(self, mountpoint, whitelist_fingerprints):
        ''' Returns a dict of fingerprints for files in mountpoints '''
        log.info("FingerPrintScanner: Started scan for fingerprints on %s." % mountpoint)
        fingerprints = dict()
        for root, dirs, files in os.walk(mountpoint, followlinks=False):
            if self.skipMountPoints:
                if log.getEffectiveLevel() == logging.DEBUG:
                    # Filter out from dirs the mountpoints = stay on same filesystem
                    temp_dirs = list(filter(lambda dir: not os.path.ismount(os.path.join(root, dir)), dirs))
                    if set(dirs) != set(temp_dirs):
                        log.debug("FingerPrintScanner: Ignored these directories as they were mountpoint: " + ', '.join(set(dirs) - set(temp_dirs)))
                    dirs[:] = temp_dirs[:]
                    # Filter out whitelist
                    temp_dirs = list(filter(lambda dir: not os.path.join(root, dir) in whitelist_fingerprints, dirs))
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
                if os.path.join(root,filename) in whitelist_fingerprints:
                    log.debug("FingerPrintScanner: Ignored " + os.path.join(root,filename) + " as it was found whitelisted.")
                    continue

                fingerprints[os.path.join(root, filename)] = getmd5(os.path.join(root, filename))
        return fingerprints

    def scan(self):
        ''' Compute fingerprints for both boot and root partition '''
        log.info("FingerPrintScanner: Started to scan for fingerprints... this will take a while...")
        root_whitelist_fingerprints = getConfigurationItem(self.conf, "FingerPrintScanner", "root_whitelist").split()
        boot_whitelist_fingerprints = getConfigurationItem(self.conf, "FingerPrintScanner", "boot_whitelist").split()
        self.root_fingerprints = self.do_scan(self.root, root_whitelist_fingerprints)
        self.boot_fingerprints = self.do_scan(self.boot, boot_whitelist_fingerprints)

    def printFingerPrints(self):
        fingerprints = "# File MD5SUM\t\t\t\tFilepath\n\nroot\n\n"
        sorted_root_fingerprints = sorted(self.root_fingerprints.items(), key=operator.itemgetter(0))
        for filename, filemd5 in sorted_root_fingerprints:
            fingerprints += filemd5 + "\t" + filename + "\n"
        fingerprints += "\n\nboot\n\n"
        sorted_boot_fingerprints = sorted(self.boot_fingerprints.items(), key=operator.itemgetter(0))
        for filename, filemd5 in sorted_boot_fingerprints:
            fingerprints += filemd5 + "\t" + filename + "\n"
        return fingerprints

    def getRootFingerPrints(self):
        return self.root_fingerprints

    def getBootFingerPrints(self):
        return self.boot_fingerprints

    def do_validateFingerPrints(self, fingerPrintFile, fingerprints):
        ''' Compares the computed fingerprints in <fingerprints> with the one in the <fingerPrintFile> file '''
        toReturn = True
        log.info("FingerPrintScanner: Validating fingerprints for " + fingerPrintFile + ".")
        try:
            with open(fingerPrintFile, 'r') as infile:
                for line in infile:
                    default_filename = line.split()[1]
                    default_filemd5 = line.split()[0]
                    for filename,filemd5 in fingerprints.items():
                        if filename == default_filename and filemd5 != default_filemd5:
                            log.warn("Fingerprint failed for: " + filename)
                            toReturn = False
        except Exception as e:
            print(e)
            return False
        return toReturn

    def validateFingerPrints(self):
        ''' Verifies if computed fingerprints match the ones in the fingerprints file'''
        toReturn = True

        # If we didn't computed fingerprints do it now
        if len(self.root_fingerprints) == 0 or len(self.boot_fingerprints) == 0:
            self.scan()

        # Compute fingerprints file for rootfs partition
        root_FingerPrintFile = getConfigurationItem(self.conf, "FingerPrintScanner", "root_defaultFingerPrintFile")
        root_FingerPrintFile = os.path.join(self.root, root_FingerPrintFile)

        # Validate root partition fingerprints
        if os.path.isfile(root_FingerPrintFile):
            if not self.do_validateFingerPrints(root_FingerPrintFile, self.root_fingerprints):
                toReturn = False
        else:
            # Rootfs fingerprints file not present on filesystem
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
                    for filename,filemd5 in self.root_fingerprints.items():
                        if filename == default_filename and filemd5 != default_filemd5:
                            log.warn("FingerPrintScanner: Fingerprint failed for: " + filename)
                            toReturn = False

        # Compute fingerprints file for boot partition
        boot_FingerPrintFile = getConfigurationItem(self.conf, "FingerPrintScanner", "boot_defaultFingerPrintFile")
        boot_FingerPrintFile = os.path.join(self.boot, boot_FingerPrintFile)

        # Validate boot partition fingerprints
        if os.path.isfile(boot_FingerPrintFile):
            if not self.do_validateFingerPrints(boot_FingerPrintFile, self.boot_fingerprints):
                toReturn = False
        else:
            # Boot fingerprints file not present on filesystem
            log.warn("FingerPrintScanner: No fingerprints file found for boot partition.")
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
        mountpoint = "./modules/fingerprint/tests/testRun/tree/dir1"
        mount(what="tmpfs", where=mountpoint, mounttype="tmpfs")

        conf = "./modules/fingerprint/tests/testRun/resinhup.conf"
        scanner = FingerPrintScanner("./modules/fingerprint/tests/testRun/root_tree", "./modules/fingerprint/tests/testRun/boot_tree", conf, "./modules/fingerprint/tests/testRun")
        scanner.scan()

        # Cleanup mount
        umount(mountpoint)

        print(scanner.printFingerPrints())

        #
        # Root directory checkings
        #
        root_whitelist_fingerprints = getConfigurationItem(conf, "FingerPrintScanner", "root_whitelist").split()
        root_fingerprints = scanner.getRootFingerPrints()

        # Check on known file
        self.assertTrue(root_fingerprints['./modules/fingerprint/tests/testRun/root_tree/dir4/file1'] == '68b329da9893e34099c7d8ad5cb9c940')

        for filename,filemd5 in root_fingerprints.items():
            self.assertFalse(filename in root_whitelist_fingerprints)
            # Check mountpoint
            self.assertFalse(filename.startswith(mountpoint))

        #
        # Boot directory checkings
        #
        boot_whitelist_fingerprints = getConfigurationItem(conf, "FingerPrintScanner", "boot_whitelist").split()
        boot_fingerprints = scanner.getBootFingerPrints()

        # Check on known file
        self.assertTrue(boot_fingerprints['./modules/fingerprint/tests/testRun/boot_tree/file1'] == '68b329da9893e34099c7d8ad5cb9c940')

        for filename,filemd5 in boot_fingerprints.items():
            self.assertFalse(filename in root_whitelist_fingerprints)

        #
        # Final validation
        #
        self.assertTrue(scanner.validateFingerPrints())



if __name__ == '__main__':
    unittest.main()
