#!/bin/bash

#########################
# HELP
#########################

export DEBIAN_FRONTEND=noninteractive

help()
{
  echo "This script installs Nebula Graph Explorer on Ubuntu"
  echo ""
  echo "Options:"
  echo "    -v      nebula explorer version, default: 3.1.2"
  echo "    -h      view default help content"
}

log()
{
    echo \[$(date +%Y/%m/%d-%H:%M:%S)\] "$1"
    echo \[$(date +%Y/%m/%d-%H:%M:%S)\] "$1" >> /var/log/nebula-explorer-install.log
}

log "Begin execution of Nebula Graph Explorer script extension on ${HOSTNAME}"
START_TIME=$SECONDS

#########################
# Preconditions
#########################

if [ "${UID}" -ne 0 ];
then
    log "Script executed without root permissions"
    echo "You must be root to run default program." >&2
    exit 3
fi

#########################
# Parameter handling
#########################

EXPLORER_VERSION="3.1.2"
NEBULA_LICENSE_PATH="/usr/local/nebula-explorer/nebula.license"
EXPLORER_SERVICE_PATH="/usr/local/nebula-explorer/lib/nebula-explorer.service"

#Loop through options passed
while getopts :v:h optname; do
  log "Option ${optname} set"
  case $optname in
  v) # set nebula version
    EXPLORER_VERSION="${OPTARG}"
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

# Install Nebula Graph Explorer
install_explorer()
{
    local PACKAGE="nebula-explorer-${EXPLORER_VERSION}.x86_64.deb"

    log "[install_explorer] installing Nebula Graph Explorer ${EXPLORER_VERSION}"

    chmod +x nebula-download
    ./nebula-download explorer --version="${EXPLORER_VERSION}"

    local EXIT_CODE=$?
        if [[ $EXIT_CODE -ne 0 ]]; then
        log "[install_explorer] error downloading Nebula Graph Explorer $EXPLORER_VERSION"
        exit $EXIT_CODE
    fi

    dpkg -i "$PACKAGE"

    log "[install_explorer] installed Nebula Graph Explorer $EXPLORER_VERSION"
}

# Security
configure_license() {
    log "[configure_license] save license to file"
    cp nebula-explorer.license ${NEBULA_LICENSE_PATH}
}

register_systemd()
{
    log "[register_systemd] configure systemd to start Explorer service automatically when system boots"
    systemctl daemon-reload
    systemctl enable ${EXPLORER_SERVICE_PATH}
}

start_explorer()
{
    log "[start_explorer] starting Explorer"
    systemctl start nebula-explorer.service
    log "[start_explorer] started Explorer"
}

#########################
# Installation sequence
#########################

# if explorer is already installed assume default is a redeploy
if systemctl -q is-active nebula-explorer.service; then
  log "[explorer] explorer service is already active"
  exit 0
fi

install_explorer

configure_license

register_systemd

start_explorer

ELAPSED_TIME=$(($SECONDS - $START_TIME))
PRETTY=$(printf '%dh:%dm:%ds\n' $(($ELAPSED_TIME/3600)) $(($ELAPSED_TIME%3600/60)) $(($ELAPSED_TIME%60)))

log "End execution of Nebula Graph Explorer script extension on ${HOSTNAME} in ${PRETTY}"
exit 0