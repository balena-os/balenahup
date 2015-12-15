# Resinhup
Tool for resin host OS updates.

## Instalation

### Pull from resin registry
```sh
[host] $ rce pull registry.resinstaging.io/resinhup/resinhup-<<machine>>
[host] $ rce tag -f registry.resinstaging.io/resinhup/resinhup-<<machine>> resinhup
```
Latest tag will point to the image build from the latest git tag. Replace &lt;&lt;machine&gt;&gt; by your target machine. Example raspberry-pi2. See https://github.com/resin-io/resinhup/blob/master/conf/resinhup for supported machines.

### Local built rce/docker images
Clone this repository on target (or transfer), change your current directoy in the one where you have the cloned copy of the repository and:
```sh
[host] $ cp Dockerfile.<machine> Dockerfile
[host] $ rce build -t resinhup .
```
Replace &lt;&lt;machine&gt;&gt; by your target machine. Example raspberry-pi2. See https://github.com/resin-io/resinhup/blob/master/conf/resinhup for supported machines.

## How to use
Prepare the image on the target by running
```sh
$ ./prepare.sh
```
This will stop all the running containers.

### Run container manually
Run the container manually using:
```sh
[host     ]$ rce run -ti --privileged --rm --net=host --volume /:/host resinhup /bin/bash
[container]$ python /app/resinhup.py --config /app/conf/resinhup.conf --debug
[container]$ exit
[host     ]$ reboot
```

### Run container automatically
Run the container automatically:
```sh
[host] $ rce run -ti --privileged --rm --net=host --volume /:/host resinhup
[host] $ reboot
```

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
