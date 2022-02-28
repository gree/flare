#!/bin/bash

PREFIX=$1
NUM=$2
OFFSET=$3


mkdir -p "tmp/${PREFIX}"

setup_index () {
cat <<EOF > "tmp/${PREFIX}/flarei.conf"
data-dir = `pwd`/tmp/${PREFIX}
log-facility = local0
max-connection = 256
monitor-threshold = 3
monitor-interval = 1
server-name = localhost
server-port = $OFFSET
thread-pool-size = 8
EOF
}

setup_node () {
    local N=$1
    local PORT=$((OFFSET+N+1))
    mkdir -p "tmp/${PREFIX}-$N"
cat <<EOF > "tmp/${PREFIX}-$N/flared.conf"
data-dir = `pwd`/tmp/${PREFIX}-$N
index-servers = localhost:$OFFSET
log-facility = local1
max-connection = 256
mutex-slot = 32
proxy-concurrency = 2
server-name = localhost
server-port = $PORT
storage-type = tch
thread-pool-size = 16
EOF

}

set -xe

#setup_index
screen -t "flarei-${PREFIX}" src/flarei/flarei -f "tmp/${PREFIX}/flarei.conf" -s
sleep 3
for((i=0;i<$NUM;i++)) ; do
    echo $i
#    setup_node $i
    screen -t "flared-${PREFIX}-$i" src/flared/flared -f "tmp/${PREFIX}-$i/flared.conf" -s
    sleep 3
done

flare-admin stats -i localhost:$OFFSET
