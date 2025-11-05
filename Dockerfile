FROM scratch

# Copies the update scripts to the app subdirectory to allow for future use of
# other subdirectories.
WORKDIR /app
COPY ./entry.sh ./entry.sh
COPY ./upgrade-2.x.sh ./upgrade-2.x.sh
