#!/bin/bash

./kubectl.sh apply -f scripts/cluster-scripts/metallb.yaml

# Deploy config
./kubectl.sh apply -f temp/metallb.yaml
