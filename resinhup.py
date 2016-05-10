#!/usr/bin/env python3

#
# ** License **
#
# Home: http://resin.io
#
# Author: Andrei Gherzan <andrei@resin.io>
#

# Default variables

import sys

import meta.resinhupmeta as meta
from modules.colorlogging import *
from modules.util import *
from modules.fingerprint import *
from modules.repartitioner import *
from fetcher.tar import *
from modules.updater import *
from argparse import ArgumentParser
import logging
from distutils.version import StrictVersion

default_resinhup_conf_file = "/etc/resinhup.conf"

def main():
    '''
    Main
    '''
    # Parse arguments
    parser = ArgumentParser(add_help=False, description=meta.description)
    parser.add_argument('-v', '--version', action='version', version = meta.version)
    parser.add_argument('-h', '--help', action='help',
                      help = 'Print this message and exit')
    parser.add_argument('-d', '--debug', action="store_true", dest = 'debug', default = False,
                      help = 'Run in debug/verbose mode')
    parser.add_argument('-n', '--no-colors', action = 'store_false', dest = 'colors', default = True,
                      help = "Don't use any colors")
    parser.add_argument('--device', action = 'store', dest = 'device', default = False,
                      help = "Force the device name and skip device detection")
    parser.add_argument('-c', '--configuration-file', action = 'store', dest = 'conf', default = default_resinhup_conf_file,
                      help = "Configuration file to be used. Default: " + default_resinhup_conf_file)
    parser.add_argument('-f', '--force-fingerprint', action = 'store_true', dest = 'force_fingerprint', default = False,
                      help = "Avoid fingerprint check and force update. Do it on your own risk.")
    parser.add_argument('-s', '--staging', action = 'store_true', dest = 'staging', default = False,
                      help = "Validate and configure config.json against staging values.")
    parser.add_argument('-u', '--update-to-version', action = 'store', dest = 'version', default = False,
                      help = "Use this version to update the device to.")
    parser.add_argument('-r', '--remote', action = 'store', dest = 'remote', default = '',
                      help = "Remote to be used when searching for update bundles. Overwrites the value in configuration file.")

    args = parser.parse_args()

    # Allow things to be overwritten from environment
    if os.getenv('REMOTE'):
        args.remote = os.getenv('REMOTE')
    if os.getenv('VERSION'):
        args.version = os.getenv('VERSION')
    if os.getenv('RESINHUP_STAGING'):
        args.staging = True
    if os.getenv('RESINHUP_FORCE'):
        args.force_fingerprint = True

    # Logger
    log = logging.getLogger()
    log.setLevel(logging.INFO)
    ch = logging.StreamHandler()
    ch.setFormatter(ColoredFormatter(args.colors))
    log.addHandler(ch)

    # Debug argument
    if args.debug:
        log.setLevel(logging.DEBUG)
        log.debug("Running in debug/verbose mode.")

    # Error if not root
    if not check_if_root():
        log.error("Updater not ran as root.")
        return False

    # Debug message for configuration file
    log.debug("Using configuration file " + args.conf)

    # Make sure version was provided
    if not args.version:
        log.error("HostOS version to update to was not provided. Check help..")
        return False
    else:
        log.info("Update version " + args.version + " selected.")

    # Board identification
    if not args.device:
        device = runningDevice(args.conf)
        if not device:
            log.error("Could not detect this board's name.")
            return False
    else:
        device = args.device

    # Device supported?
    supported = getConfigurationItem(args.conf, "General", "supported_machines")
    if not supported:
        log.error("Can't detect supported hardware")
        return False
    supported = supported.split()
    if device not in supported:
        log.error(device + " is not a supported device for resinhup.")
        return False
    log.debug(device + " is a supported device for resinhup.")

    # Is the requested version already there or greater?
    currentVersion = getCurrentHostOSVersion(args.conf)
    if currentVersion:
        if StrictVersion(currentVersion) >= StrictVersion(args.version):
            log.info("The device is (" + currentVersion + ") already at the requested or greater version than the one requested (" + args.version + ").")
            sys.exit(3)
        else:
            log.info("Updating from " + currentVersion + " to " + args.version + ".")

    # Check the image fingerprint
    if not args.force_fingerprint:
        root_mount = getConfigurationItem(args.conf, 'General', 'host_bind_mount')
        if not root_mount:
            root_mount = '/'
        images_fingerprint_path = os.path.join(os.path.dirname(sys.modules[__name__].__file__), "modules/fingerprint/known-images")
        scanner = FingerPrintScanner(root_mount, args.conf, images_fingerprint_path)
        scanner.scan()
        if not scanner.validateFingerPrints():
            log.error("Cannot validate current image fingerprint.")
            return False
        else:
            log.info("Fingerprint validation succeeded.")
    else:
        log.debug("Fingerprint scan avoided as instructed.")

    # Staging / production
    log.info("Configure update as " + ("staging" if args.staging else "production") + ".")
    if args.staging:
        if not setConfigurationItem(args.conf, "config.json", "type", "staging"):
            return False
    else:
        if not setConfigurationItem(args.conf, "config.json", "type", "production"):
            return False

    # Handle old boot partitions
    r = Repartitioner(args.conf)
    if not r.increaseResinBootTo(40):
        log.error("resinhup: Failed to increase resin-boot to 40MiB.")
        return False

    # Get new update
    f = tarFetcher(args.conf, version=args.version, remote=args.remote)
    if not f.unpack(downloadFirst=True):
        log.error("Could not unpack update")
        return False

    # Perform update
    u = Updater(f, args.conf)
    if not u.upgradeSystem():
        u.cleanup()
        log.error("Could not upgrade your system")
        return False
    u.cleanup()

    return True

if __name__ == "__main__":
    if not main():
        sys.exit(1)
    sys.exit(0)
