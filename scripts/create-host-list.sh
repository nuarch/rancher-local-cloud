#!/bin/bash

NODES=$@
for NODE in ${NODES}; do
  echo `multipass info $NODE | grep "IPv4" | awk -F' ' '{print $2}'` `echo $NODE`
done
