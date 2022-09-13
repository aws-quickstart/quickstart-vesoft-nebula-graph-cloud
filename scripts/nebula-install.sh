#!/bin/bash

#########################
# HELP
#########################

export DEBIAN_FRONTEND=noninteractive

help() {
  echo "This script installs NebulaGraph on Ubuntu"
  echo ""
  echo "Options:"
  echo "    -v      nebula version, default: 3.1.2"
  echo "    -c      nebula component, default: all"
  echo "    -m      nebula meta_server_address, default: 127.0.0.1:9559"

  echo "    -h      view default help content"
}

log() {
  echo \[$(date +%Y/%m/%d-%H:%M:%S)\] "$1"
  echo \[$(date +%Y/%m/%d-%H:%M:%S)\] "$1" >>/var/log/nebula-install.log
}

log "Begin execution of NebulaGraph script extension on ${HOSTNAME}"
log "$@"
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

NEBULA_VERSION="3.1.2"
NEBULA_COMPONENT="all"
NEBULA_LICENSE_PATH="/usr/local/nebula/share/resources/nebula.license"

#LOCAL_IP=$(ip addr | awk /"$(ip route | awk '/default/ { print $5 }')"/ | awk '/inet/ { print $2 }' | cut -f 1 -d "/")
LOCAL_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
META_SERVER_ADDRESS="127.0.0.1:9559"

FLAG_LOCAL_IP="--local_ip"
FLAG_META_SERVER_ADDRESS="--meta_server_addrs"
FLAG_DATA_PATH="--data_path"
FLAG_LOG_PATH="--log_dir"

DISK_DATA_PATH="/usr/local/nebula/data"
DISK_LOG_PATH="/usr/local/nebula/log"

SYSTEMD_PATH="/usr/lib/systemd/system"

#Define systemctl units

GRAPHD_SERVICE="[Unit]
                Description=Nebula Graph Graphd Service
                After=network.target

                [Service]
                Type=forking
                Restart=always
                RestartSec=10s
                PIDFile=/usr/local/nebula/pids/nebula-graphd.pid
                ExecStart=/usr/local/nebula/scripts/nebula.service start graphd
                ExecReload=/usr/local/nebula/scripts/nebula.service restart graphd
                ExecStop=/usr/local/nebula/scripts/nebula.service stop graphd
                PrivateTmp=true

                [Install]
                WantedBy=multi-user.target"

METAD_SERVICE="[Unit]
               Description=Nebula Graph Metad Service
               After=network.target

               [Service]
               Type=forking
               Restart=always
               RestartSec=10s
               PIDFile=/usr/local/nebula/pids/nebula-metad.pid
               ExecStart=/usr/local/nebula/scripts/nebula.service start metad
               ExecReload=/usr/local/nebula/scripts/nebula.service restart metad
               ExecStop=/usr/local/nebula/scripts/nebula.service stop metad
               PrivateTmp=true

               [Install]
               WantedBy=multi-user.target"

STORAGED_SERVICE="[Unit]
                  Description=Nebula Graph Storaged Service
                  After=network.target

                  [Service]
                  Type=forking
                  Restart=always
                  RestartSec=10s
                  PIDFile=/usr/local/nebula/pids/nebula-storaged.pid
                  ExecStart=/usr/local/nebula/scripts/nebula.service start storaged
                  ExecReload=/usr/local/nebula/scripts/nebula.service restart storaged
                  ExecStop=/usr/local/nebula/scripts/nebula.service stop storaged
                  PrivateTmp=true

                  [Install]
                  WantedBy=multi-user.target"

#Loop through options passed
while getopts :v:c:m:h optname; do
  log "Option ${optname} set"
  case $optname in
  v) #set nebula version
    NEBULA_VERSION="${OPTARG}"
    ;;
  c) #set nebula component
    NEBULA_COMPONENT="${OPTARG}"
    ;;
  m) #set meta_server_address
    META_SERVER_ADDRESS="${OPTARG}"
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

# Format data disks (Find data disks then partition, format, and mount them as seperate drives)
format_data_disks() {
  log "[format_data_disks] starting partition and format attached disks"
  bash vm-disk-utils.sh
  local EXIT_CODE=$?
  if [[ $EXIT_CODE -ne 0 ]]; then
    log "[format_data_disks] returned non-zero exit code: $EXIT_CODE"
    exit $EXIT_CODE
  fi
  log "[format_data_disks] finished partition and format attached disks"
}

# Configure NebulaGraph Data Disk Folder and Permissions
setup_data_disk() {
  if [ -d "/datadisks" ]; then
    local RAIDDISK="/datadisks/disk1"
    log "[setup_data_disk] configuring disk $RAIDDISK/nebula/data"
    mkdir -p "$RAIDDISK/nebula/data"
    chmod 755 "$RAIDDISK/nebula"
    DISK_DATA_PATH="$RAIDDISK/nebula/data"
    DISK_LOG_PATH="$RAIDDISK/nebula/log"
  else
    #If we do not find folders/disks in our data disk mount directory then use the defaults
    log "[setup_data_disk] configured data directory does not exist for ${HOSTNAME}. using defaults"
  fi
}

# Install NebulaGraph
install_nebula() {
  local OS_SUFFIX="amd64"
  local OS_VERSION="ubuntu2004"
  local PACKAGE="nebula-graph-ent-${NEBULA_VERSION}.${OS_VERSION}.${OS_SUFFIX}.deb"

  chmod +x nebula-download
  ./nebula-download nebula

  log "[install_nebula] installing NebulaGraph ${NEBULA_VERSION}"

  local EXIT_CODE=$?
  if [[ $EXIT_CODE -ne 0 ]]; then
    log "[install_nebula] error downloading NebulaGraph $NEBULA_VERSION"
    exit $EXIT_CODE
  fi

  dpkg -i "$PACKAGE"

  log "[install_nebula] installed NebulaGraph $NEBULA_VERSION"
}

# Configure NebulaGraph
configure_nebula() {
  case $NEBULA_COMPONENT in
  "graphd")
    configure_graphd
    ;;
  "metad")
    configure_metad
    ;;
  "storaged")
    configure_storaged
    ;;
  "all")
    configure_graphd
    configure_metad
    configure_storaged
    ;;
  esac
}

configure_graphd() {
  log "[configure_graphd] configure nebula-graphd.conf file"
  local GRAPHD_CONF="/usr/local/nebula/etc/nebula-graphd.conf"

  if [ -d "/datadisks" ]; then
    sed -i "s/${FLAG_LOG_PATH}.*/${FLAG_LOG_PATH}=$(echo "${DISK_LOG_PATH}" | sed -e 's/\//\\\//g')/" $GRAPHD_CONF
  fi
  configure_common_flag $GRAPHD_CONF
}

configure_metad() {
  log "[configure_metad] configure nebula-metad.conf file"
  local METAD_CONF="/usr/local/nebula/etc/nebula-metad.conf"

  if [ -d "/datadisks" ]; then
    sed -i "s/${FLAG_DATA_PATH}.*/${FLAG_DATA_PATH}=$(echo "${DISK_DATA_PATH}" | sed -e 's/\//\\\//g')/" $METAD_CONF
    sed -i "s/${FLAG_LOG_PATH}.*/${FLAG_LOG_PATH}=$(echo "${DISK_LOG_PATH}" | sed -e 's/\//\\\//g')/" $METAD_CONF
  fi

  configure_common_flag $METAD_CONF
}

configure_storaged() {
  log "[configure_storaged] configure nebula-storaged.conf file"
  local STORAGED_CONF="/usr/local/nebula/etc/nebula-storaged.conf"

  if [ -d "/datadisks" ]; then
    sed -i "s/${FLAG_DATA_PATH}.*/${FLAG_DATA_PATH}=$(echo "${DISK_DATA_PATH}" | sed -e 's/\//\\\//g')/" $STORAGED_CONF
    sed -i "s/${FLAG_LOG_PATH}.*/${FLAG_LOG_PATH}=$(echo "${DISK_LOG_PATH}" | sed -e 's/\//\\\//g')/" $STORAGED_CONF
  fi

  configure_common_flag $STORAGED_CONF
}

add_storaged_hosts() {
  log "[add_storaged_hosts] endpoints: ${META_SERVER_ADDRESS}  hosts: ${LOCAL_IP}"
  sleep 20
  chmod +x hosts-manager
  ./hosts-manager add --endpoints "${META_SERVER_ADDRESS}" --hosts "${LOCAL_IP}"

  local EXIT_CODE=$?
  if [[ $EXIT_CODE -ne 0 ]]; then
    log "[add_storaged_hosts] failed add storage hosts"
    exit $EXIT_CODE
  fi
}

configure_common_flag() {
  local COMPONENT_CONF=$1

  sed -i "s/${FLAG_LOCAL_IP}.*/${FLAG_LOCAL_IP}=${LOCAL_IP}/" "$COMPONENT_CONF"
  sed -i "s/${FLAG_META_SERVER_ADDRESS}.*/${FLAG_META_SERVER_ADDRESS}=${META_SERVER_ADDRESS}/" "$COMPONENT_CONF"
}

# Security
configure_license() {
  log "[configure_license] save license to file"
  cp nebula.license "${NEBULA_LICENSE_PATH}"
}

# Register NebulaGraph Systemd
register_systemd() {
  case $NEBULA_COMPONENT in
  "graphd")
    register_graph_systemd
    ;;
  "metad")
    register_meta_systemd
    ;;
  "storaged")
    register_storage_systemd
    ;;
  "all")
    register_graph_systemd
    register_meta_systemd
    register_storage_systemd
    ;;
  esac
}

register_graph_systemd() {
  log "[register_graph_systemd] register nebula-graphd service"
  local UNIT_NAME="nebula-graphd.service"

  echo "${GRAPHD_SERVICE}" >${SYSTEMD_PATH}/${UNIT_NAME}
  systemctl daemon-reload
  systemctl enable ${UNIT_NAME}
}

register_storage_systemd() {
  log "[register_storage_systemd] register nebula-storaged service"
  local UNIT_NAME="nebula-storaged.service"

  echo "${STORAGED_SERVICE}" >${SYSTEMD_PATH}/${UNIT_NAME}
  systemctl daemon-reload
  systemctl enable ${UNIT_NAME}
}

register_meta_systemd() {
  log "[register_meta_systemd] register nebula-metad service"
  local UNIT_NAME="nebula-metad.service"

  echo "${METAD_SERVICE}" >${SYSTEMD_PATH}/${UNIT_NAME}
  systemctl daemon-reload
  systemctl enable ${UNIT_NAME}
}

# Start NebulaGraph Systemd
start_nebula() {
  case $NEBULA_COMPONENT in
  "graphd")
    start_graph_systemd
    ;;
  "metad")
    start_meta_systemd
    ;;
  "storaged")
    start_storage_systemd
    add_storaged_hosts
    ;;
  "all")
    start_graph_systemd
    start_meta_systemd
    start_storage_systemd
    ;;
  esac
}

start_graph_systemd() {
  log "[start_graph_systemd] starting Nebula Graphd"
  systemctl start nebula-graphd.service
  log "[start_graph_systemd] started Nebula Graphd"
}

start_meta_systemd() {
  log "[start_meta_systemd] starting Nebula Metad"
  systemctl start nebula-metad.service
  log "[start_meta_systemd] started Nebula Metad"
}

start_storage_systemd() {
  log "[start_storage_systemd] starting Nebula Storaged"
  systemctl start nebula-storaged.service
  log "[start_storage_systemd] started Nebula Storaged"
}

#########################
# Installation sequence
#########################
format_data_disks

install_nebula

configure_license

setup_data_disk

configure_nebula

register_systemd

start_nebula

ELAPSED_TIME=$(($SECONDS - $START_TIME))
PRETTY=$(printf '%dh:%dm:%ds\n' $(($ELAPSED_TIME / 3600)) $(($ELAPSED_TIME % 3600 / 60)) $(($ELAPSED_TIME % 60)))

log "End execution of NebulaGraph script extension on ${HOSTNAME} in ${PRETTY}"
exit 0
