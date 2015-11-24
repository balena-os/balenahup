#!/usr/bin/env python

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
import hashlib
import operator
from util import *
from colorlogging import *

class FingerPrintScanner(object):
    def __init__(self, root, conf, skipMountPoints=True):
        self.root = root
        self.skipMountPoints = skipMountPoints
        self.fingerprints = dict()
        self.conf = conf

    def scan(self):
        whitelist_fingerprints = getConfigurationItem(self.conf, "FingerPrintScanner", "whitelist").split()
        for root, dirs, files in os.walk(self.root, followlinks=False):
            if self.skipMountPoints:
                # Filter out from dirs the mountpoints - stay on same filesystem
                dirs[:] = filter(lambda dir: not os.path.ismount(os.path.join(root, dir)), dirs)
                # Filter out whitelist
                dirs[:] = filter(lambda dir: not os.path.join(root, dir) in whitelist_fingerprints, dirs)
            for filename in files:
                if os.path.islink(os.path.join(root,filename)):
                    continue
                if not os.path.isfile(os.path.join(root,filename)):
                    continue
                if os.path.isfile(os.path.join(root,filename)) in whitelist_fingerprints:
                    continue
                with open(os.path.join(root,filename)) as f:
                    filecontent = f.read()
                    filemd5 = hashlib.md5(filecontent).hexdigest()
                    self.fingerprints[os.path.join(root, filename)] = filemd5
    def getFingerPrints(self):
        fingerprints = "# File MD5SUM\t\t\t\tFilepath\n"
        sorted_fingerprints = sorted(self.fingerprints.items(), key=operator.itemgetter(0))
        for filename, filemd5 in sorted_fingerprints:
            fingerprints += filemd5 + "\t" + filename + "\n"
        return fingerprints

    def validateFingerPrints(self):
        toReturn = True

        if len(self.fingerprints) == 0:
            self.scan()

        defaultFingerPrintFile = getConfigurationItem(self.conf, "FingerPrintScanner", "defaultFingerPrintFile")
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
            log.debug("NOT IMPLEMENTED")

        return toReturn

class MyTest(unittest.TestCase):
    def testRun(self):
        # Logger
        log = logging.getLogger()
        log.setLevel(logging.DEBUG)
        ch = logging.StreamHandler()
        ch.setFormatter(ColoredFormatter(True))
        log.addHandler(ch)

        conf = "../conf/resinhup"
        scanner = FingerPrintScanner("/var/lib/iptables", conf)
        scanner.scan()
        print scanner.getFingerPrints()

        print scanner.validateFingerPrints()

if __name__ == '__main__':
    unittest.main()
