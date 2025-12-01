FROM scratch

# Copy scripts to the root dir
WORKDIR /
COPY ./entry.sh ./entry.sh
COPY ./upgrade-2.x.sh ./upgrade-2.x.sh
