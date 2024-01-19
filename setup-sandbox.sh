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

# Steps
CURRENT_STEP=0
TOTAL_STEPS=10

datetime=$(date '+%Y%m%d_%H%M%S');
logFile="./logs/sandbox_setup_${datetime}.log"
teeLogFile="./logs/tee.log"

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
    	echo -e "\n${COLOR}Step ${CURRENT_STEP} / ${TOTAL_STEPS}:: ${1}${NOCOLOR}"
    fi

    if [ -n "$3" ]; then
        echo -e "$1" >> "$logFile"
    fi
}

# All commands must run under sudo user
command_exists() {
	command -v "$@" > /dev/null 2>&1
}

user_in_group() {
    groups $1 | grep -q "\b$2\b"
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

function check_docker() {
    if ! command_exists docker ; then
        if [ $IS_LINUX == true ]; then
            $sh_c 'curl -sSL https://get.docker.com/ | sh'
        else
            log "\tDocker does not appear to be installed" ERROR
        exit 1
        fi
    fi

    log "Testing if Docker is running" "INFO"
    testDockerAlive=`docker ps 2>&1`
    if ([[ "$testDockerAlive" = *"//./pipe/docker_engine:"* ]] || [[ "$testDockerAlive" = *"Cannot connect to the Docker daemon"* ]]); then
        log "\t${testDockerAlive}" "ERROR"
        log "\n\tDocker does not seem to be up and running" "ERROR"
        exit 1
    else
        log "\tDocker seems to be up and running" "SUCCESS"
    fi
    
    if [ $IS_WINDOWS == true ]; then
        kernelVersion=$(docker info -f "{{ .KernelVersion }}")
        if [[ $kernelVersion != *WSL2 ]]; then
          log "Docker Desktop on Windows must be configured to use the WSL 2 based engine" "ERROR"
          exit 126
        fi
    fi

    log "Testing if Docker has enough CPU and RAM Allocated" "INFO"
    minCPU=2
    minRAM=12000000000
    dockerCPU=$((`docker info -f "{{ .NCPU }}"`))
    dockerRAM=$((`docker info -f "{{ .MemTotal }}"`))
    if [[ $dockerCPU -lt $minCPU ]] || [[ $dockerRAM -lt $minRAM ]]; then
        log "\tDocker seems NOT to have enough resources:" "ERROR"
        log "\t\t${dockerCPU} CPU (minimum ${minCPU} CPU)" "ERROR"
        log "\t\t${dockerRAM} RAM (minimum ${minRAM} RAM)" "ERROR"
        exit 126
    else
        log "\tDocker seems to have enough resources:" "SUCCESS"
        log "\t\t${dockerCPU} >= ${minCPU} CPU" "SUCCESS"
        log "\t\t${dockerRAM} >= ${minRAM} RAM" "SUCCESS"
    fi

    if [ "$reg_user" != 'true' ] && ([ -r /etc/centos-release ] || [ -r /etc/redhat-release ]); then
        service docker start
        chkconfig docker on
    fi

    # Validate Installed Docker version
    if [ "$sh_c" == "" ]; then
        server_version=`docker version --format "{{.Server.Version}}"`
    else
        server_version=`$sh_c 'docker version --format "{{.Server.Version}}"'`
    fi
    if [ -z "$server_version" ]; then
        server_version=00.00
    fi

    validateDockerVersion() {
        server_major=$(echo $server_version | cut -d "." -f1)
        server_minor=$(echo $server_version | cut -d "." -f2)
        if [ $server_major -ge 20 ]
        then
            if [ $server_minor -lt 01 ] && [ $server_major -eq 18 ]
            then
                log "Error: Docker Community Edition Version installed should be greater or equal to 20.01.XX.\n       Please uninstall/remove existing Docker packages and rerun this script." "ERROR"
                exit 1
            fi
        else
            log "Error: Docker Community Edition Version installed should be greater or equal to 20.01.XX.\n       Please uninstall/remove existing Docker packages and rerun this script." "ERROR"
            exit 1
        fi
    }
    validateDockerVersion server_version

    if ! command_exists docker-compose ; then
        if [ $IS_LINUX == true ]; then
            url=https://github.com/docker/compose/releases/download/1.29.2/docker-compose-`uname -s`-`uname -m`
            if curl --output /dev/null --silent --head --fail "$url"; then
                log "Downloading docker-compose" "INFO"
            else
                log "Can't download docker-compose" "ERROR"
                exit 1
            fi

            $sh_c 'curl -L https://github.com/docker/compose/releases/download/1.29.2/docker-compose-`uname -s`-`uname -m` -o /usr/local/bin/docker-compose'
            $sh_c 'chmod +x /usr/local/bin/docker-compose'
        else
            log "docker-compose is not available" "ERROR"
        fi
    fi
}

export DEFAULT_AR_DB="AR#Admin#"
export DEFAULT_PG_DB=postgres
export DEFAULT_ARS=arsystem
export DEFAULT_ADMIN="P@ssw0rd"

read -p "Enter password for AR Server DB user (default is ${DEFAULT_AR_DB}) - " AR_DB_PSWD </dev/tty
if [ -z "$AR_DB_PSWD" ]
then
      AR_DB_PSWD="$DEFAULT_AR_DB"
fi

read -p "Enter password for PosgreSQL DB admin (default is $DEFAULT_PG_DB) - " PG_DB_PSWD </dev/tty
if [ -z "$PG_DB_PSWD" ]
then
      PG_DB_PSWD="$DEFAULT_PG_DB"
fi

read -p "Enter password for AR Server system (default is $DEFAULT_ARS) - " ARS_PSWD </dev/tty
if [ -z "$ARS_PSWD" ]
then
      ARS_PSWD="$DEFAULT_ARS"
fi

read -p "Enter password for AR Server Demo (Admin) user (default is $DEFAULT_ADMIN) - " ADMIN_PSWD </dev/tty
if [ -z "$ADMIN_PSWD" ]
then
      ADMIN_PSWD="$DEFAULT_ADMIN"
fi

cat <<EOT > sandbox-creds.env
DATABASE_USER_PASSWORD=${AR_DB_PSWD}
DB_ADMIN_PASSWORD=${PG_DB_PSWD}
POSTGRES_PASSWORD=${PG_DB_PSWD}
AR_SERVER_DB_USER_PASSWORD=${AR_DB_PSWD}
AR_SERVER_DSO_USER_PASSWORD=${ARS_PSWD}
AR_SERVER_APP_SERVICE_PASSWORD=${ARS_PSWD}
AR_SERVER_MIDTIER_SERVICE_PASSWORD=${ARS_PSWD}
AR_SERVER_PASSWORD=${ADMIN_PSWD}
MT_CONFIG_PASSWORD=${ARS_PSWD}
AR_SERVER_CONNECTION_PASSWORD=${ARS_PSWD}
AR_SERVER_MIDTIER_SERVICE_PASSWORD=${ARS_PSWD}
EOT

# Overall timer
time {
    time {
        # Checking some pre-requisites
        log "Checking docker pre-requisite"
        check_docker
    }

    time {
        log "Checking if images are downloaded"
        if [ ! -f ${ARS_IMAGE_FILE} -a ! -f docker-images/${ARS_IMAGE_FILE} ]; then
            log "\t${ARS_IMAGE_FILE} image NOT found in folder $(cwd) or $(cwd)/docker-images" "ERROR"
            log "Did you download the docker images?" "ERROR"
            exit 1
        else
            log "\t${ARS_IMAGE_FILE} image found (Correct)" "SUCCESS"
        fi
        
        if [ ! -f ${MIDTIER_IMAGE_FILE} -a ! -f docker-images/${MIDTIER_IMAGE_FILE} ]; then
            log "\t${MIDTIER_IMAGE_FILE} image NOT found in folder $(cwd) or $(cwd)/docker-images" "ERROR"
            log "Did you download the docker images?" "ERROR"
            exit 1
        else
            log "\t${MIDTIER_IMAGE_FILE} image found (Correct)" "SUCCESS"
        fi

        if [ ! -f ${AR_DB_IMAGE_FILE} -a ! -f docker-images/${AR_DB_IMAGE_FILE} ]; then
            log "\t${AR_DB_IMAGE_FILE} image NOT found in folder $(cwd) or $(cwd)/docker-images" "ERROR"
            log "Did you download the docker images?" "ERROR"
            exit 1
        else
            log "\t${AR_DB_IMAGE_FILE} image found (Correct)" "SUCCESS"
        fi
    }

    time {
        log "Creating directory structure"
        mkdir -p "postgres/data"
        mkdir -p "logs/ars/db"
        mkdir -p "logs/midtier/arsys"
        mkdir -p "logs/midtier/tomcat"
        mkdir -p "docker-images"
        
        if [ -f ${ARS_IMAGE_FILE} ]; then
            mv ${ARS_IMAGE_FILE} docker-images/
        fi
        if [ -f ${MIDTIER_IMAGE_FILE} ]; then
            mv ${MIDTIER_IMAGE_FILE} docker-images/
        fi
        if [ -f ${AR_DB_IMAGE_FILE} ]; then
            mv ${AR_DB_IMAGE_FILE} docker-images/
        fi
    }

    time {
        log "Loading docker images"
        log "Loading ${ARS_IMAGE_FILE}" "INFO"
        if ! $sh_c docker load -i docker-images/${ARS_IMAGE_FILE}; then
            log "${ARS_IMAGE_FILE} failed to load" "ERROR"
            exit 1
        fi
        log "Loading ${MIDTIER_IMAGE_FILE}" "INFO"
        if ! $sh_c docker load -i docker-images/${MIDTIER_IMAGE_FILE}; then
            log "${MIDTIER_IMAGE_FILE} failed to load" "ERROR"
            exit 1
        fi
        log "Loading ${AR_DB_IMAGE_FILE}" "INFO"
        if ! $sh_c docker load -i docker-images/${AR_DB_IMAGE_FILE}; then
            log "${AR_DB_IMAGE_FILE} failed to load" "ERROR"
            exit 1
        fi
        export ARS_IMAGE MIDTIER_IMAGE AR_DB_IMAGE
    }

    time {
        log "Preparing and starting database"
        rm -rf postgres/data/*
        
        $sh_c docker-compose -p sandbox -f sandbox.yml pull postgres

        $sh_c docker-compose -p sandbox -f sandbox.yml up -d postgres

        until [ "`docker inspect -f {{.State.Health.Status}} postgres`"=="healthy" ]; do
            $sh_c docker inspect -f {{.State.Health.Status}} postgres
            sleep 0.1;
        done;

        sleep 15
    }

    time {
        log "Restoring database"
        $sh_c docker-compose -p sandbox -f ar-db.yml run --rm -T ar-db
    }

    time {
        log "Starting sandbox containers"
        rm -rf logs/ars/db/* logs/midtier/arsys/* logs/midtier/tomcat/*
        $sh_c docker-compose -p sandbox -f sandbox.yml up -d
    }

    time {
        log "Waiting for server to be ready"
        COUNT=1
        while [ 1 ]
        do
            if curl -f http://localhost:8008/api/rx/application/healthcheck/ready -ipv6 > /dev/null 2>&1; then
                echo ""
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
}

# Connection information
log "Connection Information"
unset MSYS_NO_PATHCONV
ADMIN_USER="${ADMIN_USER:-Demo}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-P@ssw0rd}"
log "You can access Innovation Studio through url http://localhost:8008/helix/index.html#/com.bmc.arsys.rx.innovationstudio" "INFO" "SAVELOG"
log "You can access the midtier through url http://localhost:8080/arsys" "INFO" "SAVELOG"
log "Admin User is ${ADMIN_USER}" "INFO" "SAVELOG"
log "Admin Password is ${ADMIN_PASSWORD}" "INFO" "SAVELOG"
log "Remote Java debug port is 12444" "INFO" "SAVELOG"

if [ $IS_WINDOWS == true ]; then
    log "Launching the url in a web browser"
    if [ $IS_CYGWIN == true ]; then
        cygstart http://localhost:8008/helix/index.html#/com.bmc.arsys.rx.innovationstudio
    else
        start http://localhost:8008/helix/index.html#/com.bmc.arsys.rx.innovationstudio
    fi
else 
    log "Please launch this url in a web browser (http://localhost:8008/helix/index.html#/com.bmc.arsys.rx.innovationstudio)"
fi
