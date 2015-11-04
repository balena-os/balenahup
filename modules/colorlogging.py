#!/usr/bin/env python

#
# ** License **
#
# Helper for logging module to be able to use colors
#
# Home: http://resin.io
#
# Author: Andrei Gherzan <andrei@resin.io>
#

import logging

# Color codes
WHITE = 37
RED = 31
GREEN = 32
YELLOW = 33

# Sequences
RESET_SEQ = "\033[0m"
COLOR_SEQ = "\033[0;%dm"
BOLD_SEQ  = "\033[1m"
NOBOLD_SEQ  = "\033[0m"

# Map logging level to color
COLORS = {
    'WARNING': YELLOW,
    'INFO': GREEN,
    'DEBUG': WHITE,
    'CRITICAL': YELLOW,
    'ERROR': RED
}

class ColoredFormatter(logging.Formatter):
    '''
    Formatting class for using colors
    '''
    FORMAT = '%(levelname)s : %(message)s'
    def __init__(self, use_color = True):
        logging.Formatter.__init__(self, self.FORMAT)
        self.use_color = use_color

    def format(self, record):
        record.msg = record.msg.replace('[bold]', BOLD_SEQ)
        record.msg = record.msg.replace('[/bold]', NOBOLD_SEQ )
        if self.use_color and record.levelname in COLORS:
            levelname_color = COLOR_SEQ % (COLORS[record.levelname]) + record.levelname
            msg_color = record.msg + RESET_SEQ
            record.levelname = levelname_color
            record.msg = msg_color
        return logging.Formatter.format(self, record)
