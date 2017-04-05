#!/usr/bin/env python3

#
# ** License **
#
# Home: http://resin.io
#
# Author: Andrei Gherzan <andrei@resin.io>
#

import urllib3
import os
import tarfile
import logging
import shutil
from io import StringIO
from modules.util import *

log = logging.getLogger(__name__)

class tarFetcher:

    def __init__ (self, conffile, version, remote):
        if not remote:
            self.remote = getConfigurationItem(conffile, 'fetcher', 'remote')
        else:
            self.remote = remote
        self.workspace = getConfigurationItem(conffile, 'fetcher', 'workspace')
        machine = runningDevice(conffile)
        self.remotefile = os.path.join(self.remote, "resinos-" + machine, "resinhup-" + version + ".tar.gz")
        self.updatefilestream = None
        self.workspaceunpack = os.path.join(self.workspace, "update")
        self.bootfilesdir = os.path.join(self.workspace, "update/resin-boot")
        self.update_file_fingerprints = getConfigurationItem(conffile, 'fetcher', 'update_file_fingerprints').split()

    def cleanworkspace(self, remove_workdir=False):
        if os.path.isdir(self.workspace):
            shutil.rmtree(self.workspace)
        if not remove_workdir:
            os.makedirs(self.workspace)

    def cleanunpack(self, remove_unpackdir=False):
        if os.path.isdir(self.workspaceunpack):
            shutil.rmtree(self.workspaceunpack)
        if not remove_unpackdir:
            os.makedirs(self.workspaceunpack)

    def download(self):
        self.cleanworkspace()

        try:
            log.info("Downloading " + self.remotefile + " ...")
            http = urllib3.PoolManager()
            r = http.request('GET', self.remotefile, preload_content=False)
        except:
            log.error("Can't download update file.")
            return False

        if r.status != 200:
            log.error("HTTP status code: " + str(r.status))
            return False

        self.updatefilestream = r

        return True

    def testUpdate(self):
        for entry in self.update_file_fingerprints:
            if not os.path.exists(os.path.join(self.workspaceunpack, entry)):
                log.warning("Check update file failed: " + entry)
                return False

        return True

    def unpack(self, downloadFirst=False):
        if downloadFirst:
            if not self.download():
                log.error("Could not download update package.")
                return False

        self.cleanunpack()

        log.info("Unpack started... this can take a couple of seconds...")

        update = tarfile.open(mode='r|*', fileobj=self.updatefilestream)
        update.extractall(self.workspaceunpack)
        update.close()

        log.debug("Unpacked stream update file in " + self.workspaceunpack)

        if not self.testUpdate():
            log.error("Unpacked update is not a resinhup update package.")
            return False

        return True

    def unpackQuirks(self, location):
        '''Copies the content of <quirks> directory from an update to <location>.'''
        quirks_path = os.path.join(self.workspaceunpack, 'quirks')
        log.info("Unpacking rootfs quirks from " + quirks_path + " to " + location + ".")
        if not os.path.isdir(quirks_path):
            log.debug("No quirks found. Skipping.")
            return True
        if not safeCopy(quirks_path, location, sync=False):
            log.error("Failed to unpack quirks.")
            return False
        log.info("Unpack rootfs quirks done.")
        return True

    def unpackRootfs(self, location):
        log.info("Unpack rootfs started... this can take a couple of seconds or even minutes...")
        safeCopy(self.workspaceunpack, location, sync=False, ignore=['resin-boot', 'quirks'])
        log.debug("Unpacked rootfs " + self.workspaceunpack + " in " + location)
        return True

    def getBootFiles(self):
        bootfiles = []
        if not os.path.isdir(self.bootfilesdir):
            log.warn(self.bootfilesdir + " does not exist.")
        for root, dirs, files in os.walk(self.bootfilesdir):
            for name in files:
                bootfiles.append(os.path.relpath(os.path.join(root, name), self.bootfilesdir))
        return bootfiles
