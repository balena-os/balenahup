#############
# Build image
#############
FROM resin/raspberry-pi2-alpine:3.6 AS build

# Install build requirements
RUN apk add --no-cache \
      python3 gcc libc-dev parted-dev python3-dev

# Add python requirements
COPY requirements.txt ./
RUN pip3 install -r requirements.txt

# Remove cached builds to shrink image
RUN find /usr/lib/ | grep -E "(__pycache__|\.pyc|\.pyo$)" | xargs rm -rf

###############
# Shipped image
###############
FROM resin/raspberry-pi2-alpine:3.6

WORKDIR /app

# Required packages
# blkid: blkid
# dosfstools: dosfslabel
# e2fsprogs-extra: e2label
# kmod: lsmod, rmmod
# util-linux: lsblk
RUN apk add --no-cache \
      blkid btrfs-progs btrfs-progs-extra dosfstools e2fsprogs-extra jq kmod mtools parted python3 util-linux wget \
    && find /usr/lib/ | grep -E "(__pycache__|\.pyc|\.pyo$)" | xargs rm -rf

# Copy previously installed requirements
COPY --from=build /usr/lib/python3.6/site-packages /usr/lib/python3.6/site-packages

# Add the current directoy in the container
COPY app/ /app

CMD /app/run.sh
