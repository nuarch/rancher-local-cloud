#!/bin/bash
#
# Script to get xhyve working with all VPN intefaces.
# See https://gist.github.com/mowings/633a16372fb30ee652336c8417091222
#
#set -o xtrace

interfaces=( $(netstat -in | egrep 'utun\d .*\d+\.\d+\.\d+\.\d+' | cut -d ' ' -f 1) )
rulefile="rules.tmp"
echo "" > $rulefile
sudo pfctl -a com.apple/tun -F nat
for i in "${interfaces[@]}"
do
  RULE="nat on ${i} proto {tcp, udp, icmp} from 192.168.64.0/24 to any -> ${i}"
  echo $RULE >> $rulefile
done

if [[ -s $rulefile ]]; then
  echo -e "\nNAT Rules for VPN Fix:"
  cat $rulefile
  echo ""
fi

sudo pfctl -a com.apple/tun -f $rulefile

rm -rf $rulefile
