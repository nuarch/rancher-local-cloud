#!/bin/bash

case $( uname -s ) in
  MINGW*|CYGWIN*|MSYS*)
    SCRIPT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
    ;;
  *)
    SCRIPT_PATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
    ;;
esac

export KUBECONFIG=${SCRIPT_PATH}/temp/k3s.yaml

echo -e "\nKUBECONFIG set.  Use following for another shell:"
echo -e "export KUBECONFIG=${KUBECONFIG}"

export DOCKER_HOST=ssh://ubuntu@local-rancher

echo -e "\nDOCKER_HOST set.  Use following for another shell:"
echo -e "export DOCKER_HOST=${DOCKER_HOST}\n"
