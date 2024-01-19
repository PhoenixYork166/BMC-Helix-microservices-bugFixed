#!/usr/bin/env bash

# Setting MSYS_NO_PATHCONV to 1 can prevent automatic translation of a POSIX path to its Windows equivalent.
export MSYS_NO_PATHCONV=1

# Are we on MacOS or Linux?
IS_MAC_OS=false
IS_LINUX=false
IS_WINDOWS=false
IS_CYGWIN=false

unameOut="$(uname -s)"
case "${unameOut}" in
    Linux*)     IS_LINUX=true;;
    Darwin*)    IS_MAC_OS=true;;
    CYGWIN*)    IS_WINDOWS=true;
                IS_CYGWIN=true;;
    MINGW*)     IS_WINDOWS=true;;
    *)          IS_WINDOWS=true
esac

# Elapsed time
TIMEFORMAT=$'\tElapsed: %3lR seconds.'

# Color codes
# https://misc.flogisoft.com/bash/tip_colors_and_formatting
COLOR='\033[0;33m'
COLORINFO='\033[0;34m'
COLORERROR='\033[0;41m'
COLORSUCCESS='\033[0;32m'
COLORWARNING='\033[0;95m'
NOCOLOR='\033[0m'

datetime=$(date '+%Y%m%d_%H%M%S');
# Setting current script path
DEFAULT_PATH="$( cd "$(dirname "$0")" || exit ; pwd -P )"
cd "$DEFAULT_PATH"

# Log function
function log() {
    if [ -n "$2" ] && [ "$2" == "INFO" ]; then
        echo -e "${1}"
#        echo -e "${COLORINFO}${1}${NOCOLOR}"
    elif [ -n "$2" ] && [ "$2" == "ERROR" ]; then
        echo -e "${COLORERROR}${1}${NOCOLOR}"
    elif [ -n "$2" ] && [ "$2" == "SUCCESS" ]; then
        echo -e "${COLORSUCCESS}${1}${NOCOLOR}"
    elif [ -n "$2" ] && [ "$2" == "WARNING" ]; then
        echo -e "${COLORWARNING}${1}${NOCOLOR}"
    else
    	CURRENT_STEP=$((CURRENT_STEP+1))
    	echo -e "\n${COLOR}${1}${NOCOLOR}"
    fi

    if [ -n "$3" ]; then
        echo -e "$1" >> "$logFile"
    fi
}

# All commands must run under sudo user
command_exists() {
	command -v "$@" > /dev/null 2>&1
}

if [ -f images-env.sh ]; then
    . ./images-env.sh
else
    log "\tEnvironment file images-env.sh does not exist, please download it" "ERROR"
    exit 1
fi

user="$(id -un 2>/dev/null || true)"

sh_c=''

if [ $IS_LINUX == true ]; then
    reg_user='false'
    if [ "$user" != 'root' ]; then
        if user_in_group "$user" docker; then
            sh_c='sh -c'
            reg_user='true'
            log "Running as non-root user since {$user} is in the docker group, please make sure that docker daemon is started before running this script." "INFO"
        elif command_exists sudo; then
            sh_c='sudo -E sh -c'
        elif command_exists su; then
            sh_c='su -c'
        else
            log "Error: this installer needs the ability to run docker/docker-compose commands.\n       We are unable to find either \"sudo\" or \"su\" available to make this happen, or this user should be added into the docker group." "ERROR"
            exit 1
        fi
    fi
else
    reg_user='true'
fi

export ARS_IMAGE MIDTIER_IMAGE AR_DB_IMAGE

$sh_c docker-compose -p sandbox -f sandbox.yml up -d postgres

until [ "`docker inspect -f {{.State.Health.Status}} postgres`"=="healthy" ]; do
    $sh_c docker inspect -f {{.State.Health.Status}} postgres
    sleep 0.1;
done;

sleep 15

log "Starting sandbox containers"
$sh_c docker-compose -p sandbox -f sandbox.yml up -d

time {
    log "Waiting for server to be ready"
    COUNT=1
    while [ 1 ]
    do
        if curl -f http://localhost:8008/api/rx/application/healthcheck/ready -ipv6 > /dev/null 2>&1; then
            echo ""
            log "Server is ready"
            break
        else
            sleep 10
            echo -n "."
        fi
        if [ $COUNT -lt 600 ]; then
            COUNT=$((COUNT+1))
        else
            log "Innovation server failed to start !!"
            exit 126
        fi
    done
}
