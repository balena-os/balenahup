#!/usr/bin/env python3

#
# ** License **
#
# Home: http://resin.io
#
# Author: Andrei Gherzan <andrei@resin.io>
#

import parted

def revertRepartition(device, partition, deltastart, deltaend, unit='MiB'):
    dev = parted.getDevice(device)
    disk = parted.newDisk(dev)
    targetPartition = disk.getPartitionByPath(device + partition)
    geometry = targetPartition.geometry
    geometry.start += parted.sizeToSectors(deltastart, unit, dev.sectorSize)
    geometry.end += parted.sizeToSectors(deltaend, unit, dev.sectorSize)
    disk.deletePartition(targetPartition)
    partition = parted.Partition(disk=disk, type=parted.PARTITION_NORMAL, geometry=geometry)
    disk.addPartition(partition=partition, constraint=dev.optimalAlignedConstraint)
    disk.commit()
