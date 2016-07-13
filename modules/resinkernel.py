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
from .util import *
from .colorlogging import *

def rmmod(name):
    ''' Removes a kernel module from current tree '''
    cmd = "rmmod " + name
    child = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True)
    out, err = child.communicate()
    if child.returncode != 0:
        log.error("resinkernel: rmmod on " + name + " failed.")
        return False
    return True

def loaded():
    ''' Iterate through the currently loaded modules '''
    cmd = "lsmod"
    child = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True)
    out, err = child.communicate()
    if child.returncode != 0:
        log.error("resinkernel: lsmod failed.")
        return None

    lsmod = out.decode().split('\n')[1:]
    for entry in lsmod:
        entry = entry.strip()
        if not entry:
            continue
        module = entry.split()[0]
        yield module

def modinfo(name, attr):
    ''' Returns the modinfo value of the attribute requested '''
    cmd = "modinfo " + name
    child = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True)
    out, err = child.communicate()
    if child.returncode != 0:
        log.error("resinkernel: No value for " + attr + " in modinfo on " + name + " .")
        return None

    modinfo = out.decode().split('\n')
    for entry in modinfo:
        attribute = entry.split(':', 1)[0].strip()
        value = entry.split(':', 1)[1].strip()
        if attribute == attr:
            return value

    return None

class ResinKernel(object):
    def customLoadedModules(self):
        ''' Checks if any of the loaded modules are custom - loaded from custom paths '''
        log.info("ResinKernel: Checking for custom loaded kernel modules...")
        for module in loaded():
            if not modinfo(module, 'filename'):
                log.error("ResinKernel: Kernel module " + module + " seems to have been loaded from a custom path.")
                return True
        return False

class TestResinKernel(unittest.TestCase):
    def testRunWithCustomLoadedModules(self):
        ''' Needs to be ran as root '''
        # Load module
        module = './modules/resinkernel/helloworld/hello-1.ko'
        child = subprocess.Popen("insmod " + module, stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True)
        out, err = child.communicate()
        if child.returncode != 0:
            log.error("Failed to load hello-1 kernel module.")

        # Test
        k = ResinKernel()
        self.assertTrue(k.customLoadedModules())

        # Cleanup
        rmmod('hello-1')

    def testRunWithoutCustomLoadedModules(self):
        # Test
        k = ResinKernel()
        self.assertFalse(k.customLoadedModules())

if __name__ == '__main__':
    unittest.main()
