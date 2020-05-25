#!/bin/bash

IFS=$'\n'       # make newlines the only separator
set -f          # disable globbing

all_lines=$(cat temp/hosts)
for line in $all_lines; do
  host=$(echo $line | awk '{print $2}')

  case $( uname -s ) in
    MINGW*|CYGWIN*|MSYS*)
      if [ -n "$(grep $host /c/Windows/System32/drivers/etc/hosts)" ]; then
        echo "$host found in your /c/Windows/System32/drivers/etc/hosts, Removing now..."
        case $( uname -s ) in
          MINGW*|CYGWIN*|MSYS*)
          sed -i".bak" "/.*$host/d" /c/Windows/System32/drivers/etc/hosts
          ;;
          *)
          sudo sed -i".bak" "/.*$host/d" /c/Windows/System32/drivers/etc/hosts
          ;;
        esac

        echo "Removed"
      else
        echo "$host was not found in your /c/Windows/System32/drivers/etc/hosts"
      fi
    ;;
    *)
      if [ -n "$(grep $host /etc/hosts)" ]; then
        echo "$host found in your /etc/hosts, Removing now..."
        case $( uname -s ) in
          MINGW*|CYGWIN*|MSYS*)
          sed -i".bak" "/.*$host/d" /etc/hosts
          ;;
          *)
          sudo sed -i".bak" "/.*$host/d" /etc/hosts
          ;;
        esac

        echo "Removed"
      else
        echo "$host was not found in your /etc/hosts"
      fi
    ;;
  esac
done
