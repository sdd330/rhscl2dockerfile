#!/bin/bash

# this function sources *.sh in the following directories in this order:
# /usr/share/cont-layer/$1/$2.d
# /usr/share/cont-volume/$1/$2.d
source_scripts() {
    [ -z "$2" ] && return
    for dir in cont-layer cont-volume ; do
        full_dir="/usr/share/$dir/${1}/${2}.d"
        for i in ${full_dir}/*.sh; do
            if [ -r "$i" ]; then
                . "$i"
            fi
        done
    done
}

# Wait_mongo waits until the mongo server is up/down
function wait_mongo() {
    operation=-eq
    if [ $1 = "DOWN" -o $1 = "down" ]; then
        operation=-ne
    fi

    local mongo_cmd="mongo admin --host ${2:-localhost:$port} "

    for i in $(seq $MAX_ATTEMPTS); do
        echo "=> ${mongo_host} Waiting for MongoDB daemon $1"
        set +e
        $mongo_cmd --eval "quit()" &>/dev/null
        status=$?
        set -e
        if [ $status $operation 0 ]; then
            echo "=> MongoDB daemon is $1"
            return 0
        fi
        sleep $SLEEP_TIME
    done
    echo "=> Giving up: MongoDB daemon is not $1!"
    exit 1
}

# Shutdown mongod on SIGINT/SIGTERM
function cleanup() {
    echo "=> Shutting down MongoDB server"
    if [ -s $dbpath/mongod.lock ]; then
        mongod $mongo_common_args --shutdown
    fi
    wait_mongo "DOWN"

    exit 0
}

MAX_ATTEMPTS=90
SLEEP_TIME=2

mongod_config_file="/etc/mongod.conf"

# Change config file according MONGOD_CONFIG_* variables
for option in $(set | grep MONGOD_CONFIG | sed -r -e 's|MONGOD_CONFIG_||'); do
    # Delete old option from config file
    option_name=$(echo $option | sed -r -e 's|(\w*)=.*|\1|')
    sed -r -e "/^$option_name/d" $mongod_config_file > $HOME/.mongod.conf
    cat $HOME/.mongod.conf > $mongod_config_file
    rm $HOME/.mongod.conf
    # Add new option into config file
    echo $option >> $mongod_config_file
done

# Get options from config file
dbpath=$(grep dbpath $mongod_config_file | sed -r -e 's|dbpath\s*=\s*||')

# Get used port
port=27017
if grep '^\s*port' $mongod_config_file &>/dev/null; then
    port=$(grep '^\s*port' $mongod_config_file | sed -r -e 's|^\s*port\s*=\s*(\d*)|\1|')
elif grep '^\s*configsvr' $mongod_config_file &>/dev/null; then
    port=27019
elif grep '^\s*shardsvr' $mongod_config_file &>/dev/null; then
    port=27018
fi

trap 'cleanup' SIGINT SIGTERM

# Run scripts before mongod start
source_scripts mongodb pre-init

# Add default config file
mongo_common_args="-f $mongod_config_file "
mongo_local_args="--bind_ip localhost "

# Start background MongoDB service with disabled authentication
mongod $mongo_common_args $mongo_local_args &
wait_mongo "UP"

# Run scripts with started mongod
source_scripts mongodb init

# Stop background MongoDB service to exec mongod
mongod $mongo_common_args $mongo_local_args --shutdown
wait_mongo "DOWN"

# Run scripts after mongod stoped
source_scripts mongodb post-init

# Start MongoDB service with enabled authentication
exec mongod $mongo_common_args
