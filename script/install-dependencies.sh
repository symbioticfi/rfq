#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

forge install --no-git \
  foundry-rs/forge-std@rev=f3dae6e6ee381f25eb6a246f7da9b85c91a68219 \
  OpenZeppelin/openzeppelin-contracts@rev=cab19933c33c2ad1d4c7a84864a3601dddfd16f3 \
  Vectorized/solady@rev=acd959aa4bd04720d640bf4e6a5c71037510cc4b
