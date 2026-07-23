# balenaHUP
Repository for scripts to initiate and manage balena host OS updates. We maintain this repository separately from the OS and Supervisor so the scripts can adapt as needed specifically for the update.

Scripts are published as a balenaBlock to allow access from the balena registry.

## Tests

The suite under `tests/` runs with [bats](https://github.com/bats-core/bats-core), vendored as a submodule:

```sh
git submodule update --init --recursive
./tests/bats/bin/bats tests/
```
