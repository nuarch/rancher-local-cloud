#!/bin/bash

unset {HTTP_PROXY,http_proxy}
unset {HTTPS_PROXY,https_proxy}
unset {NO_PROXY,no_proxy}

kubectl $@
