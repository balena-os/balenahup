# balenaHUP
Tool for balena host OS updates. It downloads an update bundle that replaces the balenaOS for a balena device, updating both the boot partition and the rootfs (using an inactive rootfs partition).

Be aware that in the current stage of development **this tool is not meant to be ran by itself but through a** [wrapper](https://github.com/balena-os/meta-balena/blob/master/meta-balena-common/recipes-support/balenahup/balenahup/run-resinhup.sh) developed in [meta-balena](https://github.com/balena-os/meta-balena). This wrapper takes care of all the prerequisites needed for this tool and adds support for balena Supervisor updates as well. In this way, using that wrapper, a device can be updated completely (balenaOS + Supervisor).

The current development stage uses **docker images/containers to deploy and run** this tool. This is because when we first developed this tool the balenaOS was not providing all the python prerequisites needed for it to successfully work. The long term plan would be to bring it completely in the balenaOS including all the prerequisites. This is not completely decided because balenaOS has hard requirements on rootfs size and we try to keep it as small as possible. So this docker container solution is kept for now even though it adds the overhead of downloading an image before being able to run the updater.

## Docker containers versus git repository
The releases for balenaHUP are marked in this git repository as git tags. As well the git repository includes Dockerfiles for each balenaHUP supported resin board. For example there is a Dockerfile called _Dockerfile.raspberrypi3_ which is the Dockerfile for creating a balenaHUP docker image for [Raspberry Pi 3](https://www.raspberrypi.org/blog/raspberry-pi-3-on-sale/) boards. We currently upload our balenaHUP docker images to resin registry (registry.resinstaging.io). We do this because old resin devices were using docker 1.4 which can't pull from registry v2 dockerhub.

For each balenaHUP release (tag) there will be a set of docker images with the same tag uploaded to the above mentioned registry. The images have the name format: `balenaHUP-<board-slug>`. The full docker images URL format becomes `registry.resinstaging.io/balenaHUP/balenaHUP-<board slug>` .

Example. For release 1.0 (git tag 1.0), balenaHUP supports the following device slugs: beaglebone-black, intel-nuc, raspberry-pi, raspberry-pi2 and raspberrypi3. For each slug there is a corresponding Dockerfile: Dockerfile.beaglebone-black, Dockerfile.intel-nuc, Dockerfile.raspberry-pi, Dockerfile.raspberry-pi2 and Dockerfile.raspberrypi3. For each Dockerfile there are docker image pushed to the registry:

```
registry.resinstaging.io/resinhup/resinhup-raspberrypi3       1.0  c324b00459f3        2 days ago          241.4 MB
registry.resinstaging.io/resinhup/resinhup-raspberry-pi2      1.0  4ca1d77c1457        2 days ago          174.3 MB
registry.resinstaging.io/resinhup/resinhup-raspberry-pi       1.0  4ca1d77c1457        2 days ago          174.3 MB
registry.resinstaging.io/resinhup/resinhup-intel-nuc          1.0  63cc85875b84        2 days ago          225.3 MB
registry.resinstaging.io/resinhup/resinhup-beaglebone-black   1.0  7553637ea826        2 days ago          258.3 MB
```

The images taged as _latest_ are following the HEAD of master branch.

Hint: there is a script helper called [docker-build-and-push.sh](https://github.com/balena-os/balenaHUP/blob/master/scripts/docker-build-and-push.sh) for pushing images to registry. Check its help.

## How to use
Use run-resinhup.sh [wrapper](https://github.com/balena-os/meta-balena/blob/master/meta-balena-common/recipes-support/balenaHUP/balenaHUP/run-resinhup.sh) developed in [meta-balena](https://github.com/balena-os/meta-balena). Check _run-resinhup.sh_ help message for all the configuration you can use. Make sure the _run-resinhup.sh_ along with _update-resin-supervisor_ and _resin-device-progress_ scripts are updated.

Pro Hint: In order to make sure these scripts are updated and able to run balenaHUP on multiple devices (batch/fleet updates), **admins** can use a wrapper on top of _run-resinhup.sh_ called [run-resinhup-ssh.sh](https://github.com/balena-os/meta-balena/blob/master/scripts/balenaHUP/run-resinhup-ssh.sh). This wrapper is not intended for public use as it requires SSH access to the devices over VPN along with admin permissions for API queries. Check _run-resinhup-ssh.sh_ help message for all the configurations you can use.

## BalenaHUP architecture for 1.x->1.x updates
Currently there are 3 components involved in updating a device:
+ balenaHUP (docker images)
+ run-resinhup.sh (bash wrapper)
+ run-resinhup-ssh.sh (bash wrapper)

### balenaHUP

This component is distributed from this repository as docker images (explained above). The overall workflow of the tool is:
![Minion](images/resinhup-workflow.png)

### run-resinhup.sh

This is a wrapper which pulls the proper balenaHUP image and runs the updater:

+ takes care of all the prerequisites
+ adds support for supervisor update
+ pulls balenaHUP image
+ runs balenaHUP container
+ if updater is successful, reboots the board

This script is found in [balena-os/meta-balena, 1.x branch](https://github.com/balena-os/meta-balena/tree/1.X)/.

### run-resinhup-ssh.sh

This is a tool which:

+ Uploads over ssh all the needed tools from meta-balena (update-resin-supervisor, run-resinhup.sh and resin-device-progress).
+ Runs run-resinhup.sh over a set of devices and saves the log in a file called `<uuid>.resinhup.log`
+ Can run the updater over multiple devices in parallel.

It requires SSH access over VPN to devices.

This script is found in [balena-os/meta-balena, 1.x branch](https://github.com/balena-os/meta-balena/tree/1.X)/.

## balenaHUP architecture for 1.x->2.x and 2.x->2.x updates

Currently there are 2 components involved in updating a device for these versions

+ `upgrade-<...>.sh` (bash wrapper)
+ `upgrade-ssh-<...>.sh` (bash wrapper)

## upgrade-<...>.sh

The `upgrade-1.x-to-2.x.sh` and `upgrade-2.x.sh` are wrappers that which pulls the proper host OS image and runs the updater:

+ takes care of all the prerequisites
+ adds support for supervisor update
+ if updater is successful, reboots the board (default, but adjustable over command line parameters)

Run them with the `--help` flag to see all the options

### upgrade-ssh-<...>.sh

The `upgrade-ssh-1.x-to-2.x.sh` and `upgrade-ssh-2.x.sh` scripts are wrappers which:

+ Runs run-resinhup.sh over a set of devices.
+ Can run the updater over multiple devices in parallel.

It requires SSH access over VPN to devices, which is enabled for general users for balenaOS version 2.7.5 and above.

Set up your device connection settings in your SSH `config` by adding a record like this:

```
Host resindevice
  User <username>
  Hostname ssh.resindevice.io
  LogLevel ERROR
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  ControlMaster no
  IdentityFile <path-to-identity-file>
```

The `User` and `IdentityFile` sections are optional, and depend on your SSH setup. The name `resindevice` is arbitrary, and you can use any other value (unique within the `config`). That will be the name that you need to use with the `-s` command line flag.

For for [staging](https://dashboard.resinstaging.io) use `Hostname ssh.devices.resinstaging.io`.


## Development
Want to contribute? Great! Throw pull requests at us.

## TODOs
 - Safety checks for "to be updated" partition (size, existent fs etc.)
 - Use the boot file from a directory in the rootfs update partition called "/assets"
 - Add support for other resin supported targets

## Version
See balenahupmeta.py.

## License
See balenahupmeta.py.
