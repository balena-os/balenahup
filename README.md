# Resinhup
Tool for resin host OS updates. It downloads an update bundle that replaces the ResinOS for a Resin device, updating both the boot partition and the rootfs (using an inactive rootfs partition).

Be aware that in the current stage of development **this tool is not meant to be ran by itself but through a** [wrapper](https://github.com/resin-os/meta-resin/blob/master/meta-resin-common/recipes-support/resinhup/resinhup/run-resinhup.sh) developed in [meta-resin](https://github.com/resin-os/meta-resin). This wrapper takes care of all the prerequisites needed for this tool and adds support for Resin Supervisor updates as well. In this way, using that wrapper, a device can be updated completely (ResinOS + Supervisor).

The current development stage uses **docker images/containers to deploy and run** this tool. This is because when we first developed this tool the ResinOS was not providing all the python prerequisites needed for it to successfully work. The long term plan would be to bring it completely in the ResinOS including all the prerequisites. This is not completely decided because ResinOS has hard requirements on rootfs size and we try to keep it as small as possible. So this docker container solution is kept for now even though it adds the overhead of downloading an image before being able to run the updater.

## Docker containers versus git repository
The releases for resinhup are marked in this git repository as git tags. As well the git repository includes Dockerfiles for each resinhup supported resin board. For example there is a Dockerfile called _Dockerfile.raspberrypi3_ which is the Dockerfile for creating a resinhup docker image for [Raspberry Pi 3](https://www.raspberrypi.org/blog/raspberry-pi-3-on-sale/) boards. We currently upload our resinhup docker images to resin registry (registry.resinstaging.io). We do this because old resin devices were using docker 1.4 which can't pull from registry v2 dockerhub.

For each resinhup release (tag) there will be a set of docker images with the same tag uploaded to the above mentioned registry. The images have the name format: `resinhup-<board-slug>`. The full docker images URL format becomes `registry.resinstaging.io/resinhup/resinhup-<board slug>` .

Example. For release 1.0 (git tag 1.0), resinhup supports the following device slugs: beaglebone-black, intel-nuc, raspberry-pi, raspberry-pi2 and raspberrypi3. For each slug there is a corresponding Dockerfile: Dockerfile.beaglebone-black, Dockerfile.intel-nuc, Dockerfile.raspberry-pi, Dockerfile.raspberry-pi2 and Dockerfile.raspberrypi3. For each Dockerfile there are docker image pushed to the registry:

```
registry.resinstaging.io/resinhup/resinhup-raspberrypi3       1.0  c324b00459f3        2 days ago          241.4 MB
registry.resinstaging.io/resinhup/resinhup-raspberry-pi2      1.0  4ca1d77c1457        2 days ago          174.3 MB
registry.resinstaging.io/resinhup/resinhup-raspberry-pi       1.0  4ca1d77c1457        2 days ago          174.3 MB
registry.resinstaging.io/resinhup/resinhup-intel-nuc          1.0  63cc85875b84        2 days ago          225.3 MB
registry.resinstaging.io/resinhup/resinhup-beaglebone-black   1.0  7553637ea826        2 days ago          258.3 MB
```

The images taged as _latest_ are following the HEAD of master branch.

Hint: there is a script helper called [docker-build-and-push.sh](https://github.com/resin-os/resinhup/blob/master/scripts/docker-build-and-push.sh) for pushing images to registry. Check its help.

## How to use
Use run-resinhup.sh [wrapper](https://github.com/resin-os/meta-resin/blob/master/meta-resin-common/recipes-support/resinhup/resinhup/run-resinhup.sh) developed in [meta-resin](https://github.com/resin-os/meta-resin). Check _run-resinhup.sh_ help message for all the configuration you can use. Make sure the _run-resinhup.sh_ along with _update-resin-supervisor_ and _resin-device-progress_ scripts are updated.

Pro Hint: In order to make sure these scripts are updated and able to run resinhup on multiple devices (batch/fleet updates), **admins** can use a wrapper on top of _run-resinhup.sh_ called [run-resinhup-ssh.sh](https://github.com/resin-os/meta-resin/blob/master/scripts/resinhup/run-resinhup-ssh.sh). This wrapper is not intended for public use as it requires SSH access to the devices over VPN along with admin permissions for API queries. Check _run-resinhup-ssh.sh_ help message for all the configurations you can use.

## Resinhup architecture
Currently there are 3 components involved in updating a device:
+ resinhup (docker images)
+ run-resinhup.sh (bash wrapper)
+ run-resinhup-ssh.sh (bash wrapper)

### resinhup
This component is distributed from this repository as docker images (explained above). The overall workflow of the tool is:
![Minion](images/resinhup-workflow.png)

### run-resinhup.sh
This is a wrapper which pulls the proper resinhup image and runs the updater:

+ takes care of all the prerequisites 
+ adds support for supervisor update
+ pulls resinhup image
+ runs resinhup container
+ if updater is successful, reboots the board

### run-resinhup-ssh.sh 
This is a tool which:

+ Uploads over ssh all the needed tools from meta-resin (update-resin-supervisor, run-resinhup.sh and resin-device-progress).
+ Runs run-resinhup.sh over a set of devices and saves the log in a file called `<uuid>.resinhup.log`
+ Can run the updater over multiple devices in parallel.

It requires SSH access over VPN to devices.

## Development
Want to contribute? Great! Throw pull requests at us.

## Todos
 - Safety checks for "to be updated" partition (size, existent fs etc.)
 - Use the boot file from a directory in the rootfs update partition called "/assets"
 - Add support for other resin supported targets

## Version
See resinhupmeta.py.

## License
See resinhupmeta.py.

