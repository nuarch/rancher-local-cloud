#!/bin/bash
#set -o xtrace
set -e

which multipass >/dev/null 2>&1 || {
  echo -e "\nMissing Multipass.  multipass command not found." 1>&2
  exit 1
}

which multipass >/dev/null 2>&1 || {
  echo -e "\nMissing JQ.  jq command not found." 1>&2
  exit 1
}

if [ ! -f ${BASH_SOURCE%/*}/cloud.properties ]; then
    echo -e "\nMissing cloud.properties file."
    exit 1
fi
source ${BASH_SOURCE%/*}/cloud.properties


ISTIO_FLAG="false"

print_help()
{
  cat 1>&2 <<EOF
rancher-cloud Usage:
  rancher-cloud [opts]

  [General Help]
  -h - Print this message

  [Core]
  -c - Create cloud
  -d - Destroy cloud
  -u - Start cloud
  -s - Stop cloud
  -r - Restart cloud
  -i - Use Istio
  -l - List cloud nodes
  -p - Use proxy

EOF
}

while getopts ":cipdsrulh:" opt;do
  case $opt in
    h)
      print_help
      exit 1
      ;;
    c)
      CREATE_FLAG="true"
      ;;
    d)
      DELETE_FLAG="true"
      ;;
    s)
      STOP_FLAG="true"
      ;;
    r)
      RESTART_FLAG="true"
      ;;
    u)
      START_FLAG="true"
      ;;
    i)
      ISTIO_FLAG="true"
      ;;
    l)
      LIST_FLAG="true"
      ;;
    p)
      PROXY_FLAG="true"
      ;;
    \?)
      echo "Invalid arguemnts." >&2
      print_help
      exit 1
      ;;
    :)
      echo "Option -${OPTARG} requires arguement." >&2
      print_help
      exit 1
      ;;
  esac
done
shift $((OPTIND-1))

main() {
  case $( uname -s ) in
    MINGW*|CYGWIN*|MSYS*)
    # Windows OS
    # To Do - find way to check if Hyper-V is installed
    ;;
    Darwin)
    echo -e "Force sudo password entry for later use..."
    sudo echo "Password set."
    ;;
    *)
    echo -e "\nUnknown OS...script only works for Mac OS or Windows."
    exit 1
    ;;
  esac

  if [[ "${DELETE_FLAG}" = "true" ]]; then
    delete_cloud
  elif [[ "${CREATE_FLAG}" = "true" ]]; then
    mkdir -p temp
    if [[ "${PROXY_FLAG}" = "true" ]]; then
      if [[ -n $proxyUser ]]; then
        PROXY="http://$proxyUser:$proxyPassword@$proxyHost:$proxyPort"
        echo -e "Proxy is in use: $proxyUser:***@$proxyHost:$proxyPort\n"
      else
        PROXY="http://$proxyHost:$proxyPort"
        echo -e "Proxy is in use: $proxyHost:$proxyPort\n"
      fi
      NO_PROXY=$proxyNo
      export {http_proxy,HTTP_PROXY}=$PROXY
      export {https_proxy,HTTPS_PROXY}=$PROXY
      export {no_proxy,NO_PROXY}=$proxyNo

      PROXY_FILE=temp/proxy.cfg
      touch $PROXY_FILE
cat <<EOM > $PROXY_FILE
#cloud-config

write_files:
- path: /etc/profile.d/proxy.sh
  content: |
    export {http_proxy,HTTP_PROXY}=${PROXY}
    export {https_proxy,HTTPS_PROXY}=${PROXY}
    export {no_proxy,NO_PROXY}=${proxyNo}
apt:
  proxy: ${PROXY}
  http_proxy: ${PROXY}
  https_proxy: ${PROXY}
EOM
    fi

    PRE_SCRIPT_FILE=${BASH_SOURCE%/*}/scripts/pre-scripts/execute.sh
    if [ -f "$PRE_SCRIPT_FILE" ]; then
        echo -e "\nExecuting prescripts...\n"
        $PRE_SCRIPT_FILE
        echo -e "\nPre-scripts executed.\n"
    fi

    build_cloud
    install_rancher
    create_k3s_cluster
    configure_rancher_and_import_cluster
    output_info

  elif [[ "${LIST_FLAG}" = "true" ]]; then
    list_cloud_nodes
  elif [[ "${STOP_FLAG}" = "true" ]]; then
    stop_cloud
  elif [[ "${RESTART_FLAG}" = "true" ]]; then
    restart_cloud
  elif [[ "${START_FLAG}" = "true" ]]; then
    start_cloud
  else
    print_help
  fi
}

build_cloud() {

  echo "Provision Ubuntu VMs using multipass...\n"

  # Create vms
  echo -e "\nCreating nodes..."
  NODES=$(eval echo local-rancher worker{1..$workerCount})
  WORKER_NODES=$(eval echo worker{1..$workerCount})

  # Rancher and K3 Control Plane node
  echo "local-rancher node: cpus: ${masterCpu}; mem: ${masterMem}; disk: ${masterDisk}"
  if [[ "$PROXY_FLAG" = "true" ]]; then
    if [[ -f "$PROXY_FILE" ]]; then
      multipass launch --name local-rancher --cpus $masterCpu --mem $masterMem --disk $masterDisk --cloud-init $PROXY_FILE
    fi
  else
    multipass launch --name local-rancher --cpus $masterCpu --mem $masterMem --disk $masterDisk
  fi

  ### Create MetalLB config

  # Trim last octate of local-rancher ip
  BASE_IP=$(echo `multipass info local-rancher | grep IPv4 | awk '{print $2}' | cut -d'.' -f1-3`)
  METALLB_IP_RANGE="${BASE_IP}.200-${BASE_IP}.249"
  sed "s/@addresses/${METALLB_IP_RANGE}/g" scripts/cluster-scripts/metallb.yaml.template > temp/metallb.yaml

  # K3 worker nodes
  for NODE in ${WORKER_NODES}; do
    echo "${NODE} node: cpus: ${workerCpu}; mem: ${workerMem}; disk: ${workerDisk}"
    if [[ "$PROXY_FLAG" = "true" ]]; then
      if [[ -f "$PROXY_FILE" ]]; then
        multipass launch --name ${NODE} --cpus $workerCpu --mem $workerMem --disk $workerDisk --cloud-init $PROXY_FILE
      fi
    else
    multipass launch --name ${NODE} --cpus $workerCpu --mem $workerMem --disk $workerDisk
    fi
  done

  sleep 10

  echo -e "Nodes created\n"

  # Create the hosts file
  scripts/create-host-list.sh $NODES > temp/hosts

  echo "Updating nodes with keys, host names, and certs..."

  for NODE in ${NODES}; do
    echo -e "\nNode ${NODE} - add personal RSA key and writing host entries to nodes /etc/hosts file."
    multipass transfer temp/hosts ${NODE}:
    multipass transfer ~/.ssh/id_rsa.pub ${NODE}:
    multipass exec ${NODE} -- sudo iptables -P FORWARD ACCEPT
    multipass exec ${NODE} -- bash -c 'sudo cat /home/ubuntu/id_rsa.pub >> /home/ubuntu/.ssh/authorized_keys'
    multipass exec ${NODE} -- bash -c 'sudo chown ubuntu:ubuntu /etc/hosts'
    multipass exec ${NODE} -- bash -c 'sudo cat /home/ubuntu/hosts >> /etc/hosts'

    OS_SCRIPT_FILE=${BASH_SOURCE%/*}/scripts/os-scripts/execute.sh
    if [ -f "$OS_SCRIPT_FILE" ]; then
        echo -e "\nExecuting OS scripts...\n"
        $OS_SCRIPT_FILE $NODE
        echo -e "\nOS scripts executed.\n"
    fi
  done

  sleep 10

  echo -e "Completed keys, host names, and certs updates.\n"

  case $( uname -s ) in
    MINGW*|CYGWIN*|MSYS*)
      cp /c/Windows/System32/drivers/etc/hosts temp/hosts.old
      cp temp/hosts.old temp/etchosts
      cat temp/hosts | tee -a temp/etchosts
      cp temp/etchosts /c/Windows/System32/drivers/etc/hosts
      ;;
    *)
      cp /etc/hosts temp/hosts.old
      cp temp/hosts.old temp/etchosts
      cat temp/hosts | sudo tee -a temp/etchosts
      # workaround to get rid of characters appear as ^M in the hosts file (OSX Catalina)
      tr '\r' '\n' < temp/etchosts > temp/etchosts.unix
      sudo cp temp/etchosts.unix /etc/hosts
      ;;
  esac

  ### Update workstation ssh settings
  LOCAL_RANCHER_IP=$(echo `multipass info local-rancher | grep IPv4 | awk '{print $2}'`)
  ssh-keygen -R $LOCAL_RANCHER_IP
  ssh-keygen -R local-rancher
  ssh-keyscan -H local-rancher >> ~/.ssh/known_hosts

  echo -e "\nVMs provisioned.\n"
}

delete_cloud() {
  #Clean up host file entries
  scripts/remove-host-entries.sh

  multipass delete --all
  multipass purge

  rm -rf temp
}

stop_cloud() {
  multipass stop --all
}

restart_cloud() {
  multipass restart --all
}

start_cloud() {
  multipass start --all
}

list_cloud_nodes() {
  multipass list
}

install_rancher() {

  echo -e "\nInstalling Rancher on node 1 (master node)...\n"

  echo "Adding docker"

  # Do not use snap pacakage as there are known issues using it with K3
  # multipass exec local-rancher -- bash -c 'sudo snap install docker'
  multipass exec local-rancher -- bash -c 'sudo apt-get update -y'
  multipass exec local-rancher -- bash -c 'sudo apt install -y docker.io'
  multipass exec local-rancher -- bash -c 'sudo usermod -aG docker ubuntu'

  # Configure proxy for Docker
  local containerProxyCommand
  if [[ -n $PROXY ]]; then
    SERVER_IP=$(echo `multipass info local-rancher | grep "IPv4" | awk -F' ' '{print $2}'`)

    # Needed for starting rancher
    containerProxyCommand="-e http_proxy=${PROXY} -e https_proxy=${PROXY} -e no_proxy=${NO_PROXY}"
    echo $containerProxyCommand

    multipass exec local-rancher -- bash -c 'sudo sh -c "mkdir -p /etc/systemd/system/docker.service.d"'

    # Setup proxy
    multipass exec local-rancher -- bash -c 'sudo sh -c "echo [Service] >> /etc/systemd/system/docker.service.d/http-proxy.conf"'
    multipass exec local-rancher -- bash -c 'sudo sh -c "echo Environment=\"HTTP_PROXY='${PROXY}'\" \"NO_PROXY='${NO_PROXY}'\" >> /etc/systemd/system/docker.service.d/http-proxy.conf"'
    multipass exec local-rancher -- bash -c 'sudo sh -c "echo [Service] >> /etc/systemd/system/docker.service.d/https-proxy.conf"'
    multipass exec local-rancher -- bash -c 'sudo sh -c "echo Environment=\"HTTPS_PROXY='${PROXY}'\" \"NO_PROXY='${NO_PROXY}'\" >> /etc/systemd/system/docker.service.d/https-proxy.conf"'
  fi

  multipass exec local-rancher -- bash -c 'sudo systemctl daemon-reload'
  multipass exec local-rancher -- bash -c 'sudo systemctl start docker'
  multipass exec local-rancher -- bash -c 'sudo systemctl enable docker'

  # Give some time for docker to up
  sleep 30

  # Add local workstation certs
  echo "Copy certs to local-rancher:/home/ubuntu"

  if [[ -d "certs/custom" && ! -z "$(ls -A certs/custom)" ]]; then
    multipass transfer certs/custom/*.pem local-rancher:
    multipass transfer certs/custom/*.crt local-rancher:
  else
    multipass transfer certs/rancher/*.pem local-rancher:
    multipass transfer certs/rancher/*.crt local-rancher:
  fi



  # Rancher set to run on port 9090/9443 as K3 uses 80, 443, and 8080.
  echo -e "\nInstalling Rancher (latest version)"
  multipass exec local-rancher -- bash -c \
  'sudo docker run -d --restart=unless-stopped --name rancher-server -p 9090:80 -p 9443:443 --privileged '"${containerProxyCommand}"' -v /home/ubuntu/cert.pem:/etc/rancher/ssl/cert.pem -v /home/ubuntu/key.pem:/etc/rancher/ssl/key.pem -v /home/ubuntu/cacerts.pem:/etc/rancher/ssl/cacerts.pem rancher/rancher:latest'
  echo -e "\nRancher installed.\n"
}

create_k3s_cluster() {

  #*** Create Kubernetes cluster using K3 ************************************************************

  echo -e "Creating Kubernetes cluster using K3s (by Rancher)...\n"

  # Deploy k3s master on rancher node

  #*** Note: k3s install scripts pull proxy info from PS
  if [[ "${ISTIO_FLAG}" = "true" ]]; then
    # https://github.com/rancher/k3d/issues/104
    multipass exec local-rancher -- bash -l -c "curl -ksfL https://get.k3s.io |INSTALL_K3S_EXEC='--no-deploy traefik' sh -"
  else
    multipass exec local-rancher -- bash -l -c "curl -ksfL https://get.k3s.io | sh -"
  fi

  # Get the IP of the master node
  K3S_NODEIP_MASTER="https://$(multipass info local-rancher | grep "IPv4" | awk -F' ' '{print $2}'):6443"

  # Get the TOKEN from the master node
  K3S_TOKEN="$(multipass exec local-rancher -- bash -c "sudo cat /var/lib/rancher/k3s/server/node-token")"

  # Deploy k3s on the worker nodes
  for NODE in ${WORKER_NODES}; do
    multipass exec ${NODE} -- bash -l -c "curl -ksfL https://get.k3s.io | K3S_TOKEN=${K3S_TOKEN} K3S_URL=${K3S_NODEIP_MASTER} sh -"
  done
  sleep 10

  multipass exec local-rancher -- bash -c "sudo cat /etc/rancher/k3s/k3s.yaml" > temp/k3s.yaml
  sed -i'.back' -e 's/127.0.0.1/local-rancher/g' temp/k3s.yaml
  export KUBECONFIG=temp/k3s.yaml
  ./kubectl.sh taint node local-rancher node-role.kubernetes.io/master=effect:NoSchedule

  CLUSTER_SCRIPT_FILE=${BASH_SOURCE%/*}/scripts/cluster-scripts/execute.sh
  if [ -f "$CLUSTER_SCRIPT_FILE" ]; then
      echo -e "\nExecuting clsuter scripts...\n"
      $CLUSTER_SCRIPT_FILE
      echo -e "\nCluster scripts executed.\n"
  fi
}

configure_rancher_and_import_cluster() {
  RANCHER_SERVER=https://local-rancher:9443

  # Login with default credentials
  while true; do

    LOGIN_RESPONSE=`curl --noproxy '*' \
      -ks $RANCHER_SERVER'/v3-public/localProviders/local?action=login' \
      -H 'content-type: application/json' \
      --data-binary '{"username":"admin","password":"admin"}'`
    LOGIN_TOKEN=`echo $LOGIN_RESPONSE | jq -r .token`
    if [ "$LOGIN_TOKEN" != "null" ]; then
        break
    else
        sleep 5
    fi
  done

  # Change password
  curl --noproxy '*' -ks $RANCHER_SERVER'/v3/users?action=changepassword'\
    -H 'content-type: application/json' \
    -H "Authorization: Bearer $LOGIN_TOKEN" \
    --data-binary '{"currentPassword":"admin","newPassword":"'$rancherPassword'"}'

  # Create API Key that does not expire
  API_RESPONSE=`curl --noproxy '*' \
    -ks $RANCHER_SERVER'/v3/token' \
    -H 'content-type: application/json' \
    -H "Authorization: Bearer $LOGIN_TOKEN" \
    --data-binary '{"type":"token","description":"automation"}'`
  API_TOKEN=`echo $API_RESPONSE | jq -r .token`

  # Set server-url
  SERVER_RESPONSE=`curl --noproxy '*' -ks $RANCHER_SERVER'/v3/settings/server-url' \
  -H 'content-type: application/json' \
  -H "Authorization: Bearer $API_TOKEN" \
  -X PUT \
  --data-binary '{"name":"server-url","value":"'$RANCHER_SERVER'"}'`

  # Set telemetry option
  TELEMETRY_RESPONSE=`curl --noproxy '*' -ks $RANCHER_SERVER'/v3/settings/telemetry-opt' \
  -H 'content-type: application/json' \
  -H "Authorization: Bearer $API_TOKEN" \
  -X PUT \
  --data-binary '{"name":"telemetry-opt","value":"'$rancherTelemetry'"}'`

  #### Create import cluster command

  # Create cluster id
  CLUSTER_RESPONSE=`curl --noproxy '*' \
   -ks $RANCHER_SERVER'/v3/cluster' \
   -H 'content-type: application/json' \
   -H "Authorization: Bearer $API_TOKEN" \
   -X POST \
   --data-binary '{"dockerRootDir":"/var/lib/docker","enableNetworkPolicy":false,"type":"cluster","name":"k3s"}'`
   CLUSTER_ID=`echo $CLUSTER_RESPONSE | jq -r .id`

  # Generate registration token
  IMPORT_CMD=`curl --noproxy '*' -ks $RANCHER_SERVER'/v3/clusterregistrationtoken' \
    -H 'content-type: application/json' \
    -H "Authorization: Bearer $API_TOKEN" \
    --data-binary '{"type":"clusterRegistrationToken","clusterId":"'"$CLUSTER_ID"'"}' | jq -r .command`

  # Import cluster into Rancher
  FIXED_IMPORT_CMD=$(echo ${IMPORT_CMD/kubectl/.\/kubectl.sh})
  echo $PWD
  echo $FIXED_IMPORT_CMD
  eval $FIXED_IMPORT_CMD
}

output_info() {

  echo -e "\nRancher is up and ready at: https://local-rancher:9443"
  echo "Username: admin"
  echo "Password: $rancherPassword"
  echo -e "\nNote: It may take a few minutesfor K3s cluster to complete registration."
}

# Invoke main
main
