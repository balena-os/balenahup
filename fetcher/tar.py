#!/usr/bin/env python3

#
# ** License **
#
# Home: http://resin.io
#
# Author: Andrei Gherzan <andrei@resin.io>
#

import requests
import os
import tarfile
import logging
import shutil
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
        self.workspacefile = os.path.join(self.workspace, "resinhup.tar.gz")
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
            log.info("Download started... this can take a couple of minutes...")
            log.debug("Downloading " + self.remotefile + " ...")
            r = requests.get(self.remotefile, stream=True)
        except:
            log.error("Can't download update file.")
            return False

        if r.status_code != 200:
            log.error("HTTP status code: " + str(r.status_code))
            return False

        with open(self.workspacefile, 'wb') as fd:
            for chunk in r.iter_content(1000000):
                fd.write(chunk)

        return True

    def testUpdate(self):
        if not os.path.exists(self.workspacefile):
            log.error("No such file: " + self.workspacefile)
            return False
        if not tarfile.is_tarfile(self.workspacefile):
            log.error(self.workspacefile + " doesn't seem to be a tar archive.")
            return False

        update = tarfile.open(self.workspacefile)
        namelist = update.getnames()
        for entry in self.update_file_fingerprints:
            if not entry in namelist:
                update.close()
                log.warning("Check update file failed: " + entry)
                return False
        update.close()

        return True

    def unpack(self, downloadFirst=False):
        if downloadFirst:
            if not self.download():
                log.error("Could not download update package.")
                return False

        self.cleanunpack()

        if not self.testUpdate():
            log.error(self.workspacefile + " not an update file.")
            return False

        log.info("Unpack started... this can take a couple of seconds...")

        update = tarfile.open(name=self.workspacefile, mode='r:*')
        update.extractall(self.workspaceunpack)

        log.debug("Unpacked " + self.workspacefile + " in " + self.workspaceunpack)
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
