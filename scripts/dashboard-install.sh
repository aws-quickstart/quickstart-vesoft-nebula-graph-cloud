#!/bin/bash

#########################
# HELP
#########################

export DEBIAN_FRONTEND=noninteractive

help() {
  echo "This script installs Nebula Graph Dashboard on Ubuntu"
  echo ""
  echo "Options:"
  echo "    -v      nebula dashboard version, default: 3.1.3"
  echo "    -g      nebula graph ips, seperated by comma,"
  echo "    -m      nebula meta ips, seperated by comma,"
  echo "    -s      nebula storage ips, seperated by comma,"
  echo "    -k      ssh private key"
  echo "    -h      view default help content"
}

log() {
  echo \[$(date +%Y/%m/%d-%H:%M:%S)\] "$1"
  echo \[$(date +%Y/%m/%d-%H:%M:%S)\] "$1" >>/var/log/nebula-dashboard-install.log
}

log "Begin execution of Nebula Graph Dashboard script extension on ${HOSTNAME}"
START_TIME=$SECONDS

#########################
# Preconditions
#########################

if [ "${UID}" -ne 0 ]; then
  log "Script executed without root permissions"
  echo "You must be root to run default program." >&2
  exit 3
fi

#########################
# Parameter handling
#########################

DASHBOARD_VERSION="3.1.3"
DASHBOARD_PATH="/usr/local/nebula-dashboard"
NEBULA_LICENSE_PATH="${DASHBOARD_PATH}/nebula-dashboard-ent/nebula.license"

#Loop through options passed
while getopts :v:g:m:s:k:h optname; do
  log "Option ${optname} set"
  case $optname in
  v) #set nebula version
    DASHBOARD_VERSION="${OPTARG}"
    ;;
  g) #set nebula graph ips
    NEBULA_GRAPH_IPS="${OPTARG}"
    ;;
  m) #set nebula meta ips
    NEBULA_META_IPS="${OPTARG}"
    ;;
  s) #set nebula storage ips
    NEBULA_STORAGE_IPS="${OPTARG}"
    ;;
  k) #set ssh private key
    SSH_PRIVATE_KEY="${OPTARG}"
    ;;
  h) #show help
    help
    exit 2
    ;;
  \?) #unrecognized option - show help
    echo -e \\n"Option -${BOLD}$OPTARG${NORM} not allowed."
    help
    exit 2
    ;;
  esac
done

#########################
# Installation steps as functions
#########################

# Install Nebula Graph Dashboard
install_dashboard() {
  log "[install_dashboard] graph ips ${NEBULA_GRAPH_IPS}"
  log "[install_dashboard] meta ips ${NEBULA_META_IPS}"
  log "[install_dashboard] storage ips ${NEBULA_STORAGE_IPS}"

  local PACKAGE="nebula-dashboard-ent-${DASHBOARD_VERSION}.linux-amd64.tar.gz"

  log "[install_dashboard] installing Nebula Graph Dashboard ${DASHBOARD_VERSION}"

  chmod +x nebula-download
  ./nebula-download dashboard --version="${DASHBOARD_VERSION}"

  local EXIT_CODE=$?
  if [[ $EXIT_CODE -ne 0 ]]; then
    log "[install_dashboard] error downloading Nebula Graph Dashboard $DASHBOARD_VERSION"
    exit $EXIT_CODE
  fi

  mkdir -p $DASHBOARD_PATH
  tar -zxvf "$PACKAGE" -C $DASHBOARD_PATH

  log "[install_dashboard] installed Nebula Graph Dashboard $DASHBOARD_VERSION"
}

# Security
configure_license() {
  log "[configure_license] save license to file"
  cp nebula-dashboard.license $NEBULA_LICENSE_PATH
}

start_dashboard() {
  log "[start_dashboard] starting Dashboard"
  $DASHBOARD_PATH/nebula-dashboard-ent/scripts/dashboard.service start all
  log "[start_dashboard] started Dashboard"

  sleep 10
  fuser 7005/tcp
  local EXIT_CODE=$?
  if [[ $EXIT_CODE -ne 0 ]]; then
    log "[start_dashboard] start dashboard failed: $EXIT_CODE"
    exit $EXIT_CODE
  fi

  log "[start_dashboard] start dashbaord succeed"
}

import_cluster() {
    cat << EOF > cluster.json
{
  "name": "nebulagraph_aws",
  "vesion": "v$DASHBOARD_VERSION",
  "nebulaType": "enterprise",
  "machines": [],
  "graphd": [],
  "metad": [],
  "storaged": []
}
EOF

  apt install jq -y

  graph_ips=$(echo "$NEBULA_GRAPH_IPS" | tr "," " ")
  meta_ips=$(echo "$NEBULA_META_IPS" | tr "," " ")
  storage_ips=$(echo "$NEBULA_STORAGE_IPS" | tr "," " ")
  machines=("${graph_ips[*]}" "${meta_ips[*]}"  "${storage_ips[*]}")

  cluster=$(jq . cluster.json)
  for ip in ${graph_ips[*]}; do
    cluster="$(jq --arg host "$ip" '.graphd += [{"host": $host, "port": 9669, "httpPort": 19669}]' <<< "$cluster")"
  done
  for ip in ${meta_ips[*]}; do
    cluster="$(jq --arg host "$ip" '.metad += [{"host": $host, "port": 9559, "httpPort": 19559}]' <<< "$cluster")"
  done
  for ip in ${storage_ips[*]}; do
    cluster="$(jq --arg host "$ip" '.storaged += [{"host": $host, "port": 9779, "httpPort": 19779}]' <<< "$cluster")"
  done
  for ip in ${machines[*]}; do
    cluster="$(jq --arg host "$ip" --arg key "$SSH_PRIVATE_KEY" '.machines += [{"host": $host, "sshUser": "ec2-user", "sshKey": $key, "sshType": "key", "sshPort": 22}]' <<< "$cluster")"
  done

  log "$cluster"
  echo "$cluster" > cluster.json

  log "[import_cluster] waiting for nebula cluster ready"
  sleep 100
  log "[import_cluster] importing cluster"
  login_resp=$(curl -sS -X POST -H "Content-type: application/json" -d '{"username": "nebula", "password": "nebula", "type": "admin"}' http://127.0.0.1:7005/api/v1/account/login)
  login_code=$(echo "${login_resp}" | jq '.code')
  if [ "$login_code" -eq 0 ]; then
    token=$(echo "${login_resp}" | jq '.data.token' | sed 's/"//g')
    import_resp=$(curl -sS -X POST -H "Content-type: application/json" -H "Authorization: Bearer $token" -d "@cluster.json" http://127.0.0.1:7005/api/v1/clusters/import)
    import_code=$(echo "${import_resp}" | jq '.code')
    if [ "$import_code" -ne 0 ]; then
      log "[import_cluster] import cluster returned non-zero code: $import_code"
      exit 1
    fi
  else
    log "[import_cluster] login dashboard returned non-zero code: $login_code"
    exit 1
  fi
  log "[import_cluster] import cluster succeed"
}

#########################
# Installation sequence
#########################

# if dashboard is already installed assume default is a redeploy
if systemctl -q is-active nebula-dashboard.service; then
  log "[dashboard] dashboard service is already active"
  exit 0
fi

install_dashboard

configure_license

start_dashboard

#import_cluster

ELAPSED_TIME=$(($SECONDS - $START_TIME))
PRETTY=$(printf '%dh:%dm:%ds\n' $(($ELAPSED_TIME / 3600)) $(($ELAPSED_TIME % 3600 / 60)) $(($ELAPSED_TIME % 60)))

log "End execution of Nebula Graph Dashboard script extension on ${HOSTNAME} in ${PRETTY}"
exit 0
