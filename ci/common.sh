#!/bin/bash

message () {
  echo -e "\e[1m\e[33m${*}\e[0m"
}
set -o verbose
set -o xtrace
set -o pipefail
set -o errexit
set -o nounset

message "Versions"
cabal --version
ghc   --version
hpack --version

PKGS=(json-alt run-haskell-module json-autotype)

message "Run hpack"
for PKG in "${PKGS[@]}"; do
  (cd $PKG; hpack);
done
