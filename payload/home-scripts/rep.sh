#!/usr/bin/env bash

grep -rlZ --exclude-dir=node_modules -F -- "$1" . |
  xargs -0 -r sed -i "s|$1|$2|g"
