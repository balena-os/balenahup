# Resinhup
Tool for resin host OS updates.

### How to use
Prepare the image on the target by running
```sh
$ ./prepare.sh
```
This will stop all the running containers and build the resinhup rce/docker image.

Run the container manually using:
```sh
[host     ]$ rce run -ti --privileged --rm --net=host --volume /:/host resinhup /bin/bash
[container]$ python /app/resinhup.py --config /app/conf/resinhup --debug
[host     ]$ reboot
```
Or simply run the container automatically:
```sh
$ rce run -ti --privileged --rm --net=host --volume /:/host resinhup
```

### Installation
Clone this repository on target (or transfer).

### Development
Want to contribute? Great! Throw pull requests at us.

### Todos
 - Develop mechanism for known footprints
 - Add support for other resin supported targets

### Version
See resinhupmeta.py.

### License
See resinhupmeta.py.
