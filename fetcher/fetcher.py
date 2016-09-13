#!/usr/bin/env python3

#
# ** License **
#
# Home: http://resin.io
#
# Author: Andrei Gherzan <andrei@resin.io>
#

import logging
from fetcher.tar import tarFetcher
from fetcher.dockerhub import dockerhubFetcher

log = logging.getLogger(__name__)

class Fetcher(object):
    def __new__ (cls, fetcher_type, conffile, version, remote):
        if fetcher_type == 'tar':
            return tarFetcher(conffile, version, remote)
        elif fetcher_type == 'dockerhub':
            return dockerhubFetcher(conffile, version, remote)
        else:
            return None
