# flare command manual

## Commands compatible with memcached

### Data operation commands

#### get 

**syntax**

    get [key name]

**response**

    VALUE [key name] [flag] [expiration time]
    (value)

Get value by key name.

#### set

**syntax**

    set [key name] [flag] [expiration time] [size of value]
    [value]

**response**

    STORED

- flag: the flag indicating whether or not to compress the value.
- expiration time: time [sec] to be erased. If you set this option `0`, the key will not be erased.

Set a key unconditionally.
If the key already exists, it will be overwritten.

#### add

**syntax**

    add [key name] [flag] [expiration time] [size of value]
    [value]

**response**

    STORED

Add a key.
If the key already exists, it will NOT be overwritten and abort writing.

#### replace

**syntax**

    replace [key name] [flag] [expiration time] [size of value]
    [value]

**response**

    STORED

Overwrite existing key.
If the key doesn't exist, abort writing.

#### append

**syntax**

    append [key name] [flag] [expiration time] [size of value]
    [value]

**response**

    STORED

Append value to existing key.
If the key doesn't exist, abort writing.

#### prepend

**syntax**

    prepend [key name] [flag] [expiration time] [size of value]
    [value]

**response**

    STORED

Prepend value to existing key.
If the key doesn't exist, abort writing.

#### incr

**syntax**

    incr [key name] [number]

**response**

    (incremented value)

Increments numerical key value by given number.
If the key value is not numeric value, it will be treated `0`.

#### decr

**syntax**

    decr [key name] [number]

**response**

    (decremented value)

Decrements numerical key value by given number.
If the key value is not numeric value, the value will be `0`.

#### delete

**syntax**

    delete [key name]

**response**

    DELETED

Deletes an existing key.

### Node operation commands

#### version

**syntax**

    version

**response**

    VERSION flare-X.X.X

Prints server version.

#### quit

**syntax**

    quit

Terminate telnet session.

### Command options

#### noreply option

available on set/add/replace/append/prepend/incr/decr commands, like:

    set key1 0 0 3 noreply

If this option is specified, response will NOT be returned.


## Commands incompatible with memcached

### Data operation commands

#### flush_all

**syntax**

    flush_all

**response**

    OK

Clear all data from terget node.

#### dump

**syntax**

    dump ([wait]) ([partition]) ([partition size])

**response**

    VALUE [key] [flag] [size of value] [version] [expiration time]
    (value)
    ...
    END

- wait: wait msec for each key retrieval (msec) (default = 0)
- partition: target partition to dump
- partition size: partition size to calculate parition

Dump all the data in the target node. If partition arguments are specified, only data in target partition are dumped.

#### dump_key (>= 1.1.0)

**syntax**

    dump_key ([partition]) ([partition size])

**response**

    KEY [key]
    ...
    END

- partition: target partition to dump
- partition size: partition size to calculate parition

Dump all the keys in the target node. If partition arguments are specified, only keys in target partition are dumped.

### Node operation commands

#### kill

**syntax**

    kill [thread id]

**response**

    OK

Kill specified thread (thread id is identified via "stats threads").

#### node add (index server only)

**syntax**

    node add [server name] [server port]

**response**

    OK

Node server sends this command at startup (internal command).

#### node role (index server only)

**syntax**

    node role [server name] [server port] [role=(master|slave|proxy)] [balance] ([partition])

**response**

    OK

Shift node role.

#### node state (index server only)

**syntax**

    node state [server name] [server port] [state=(active|prepare|down)]

**response**

    OK

Shift node state.

#### node remove (index server only)

**syntax**

    node remove [server name] [server port]

Remove node from index server (only available if target node is down).

#### node sync (index server only)

**syntax**

    node sync
    NODE [server name] [server port] [role] [state] [partition] [balance] [thread type]
    ...

**response**

    OK

Index server sends this command to each node if index server detects any change of role or state (internal command).

#### ping

**syntax**

    ping

**response**

    OK

Always return "OK" (internal command - to watch each node).

#### stats nodes

**syntax**

    stats nodes

**response**

    STAT [node key]:role [value=(master|slave|proxy)]
    STAT [node_key]:state [value=(active|prepare|down)]
    STAT [node_key]:partition [value]
    STAT [node_key]:balance [value]
    STAT [node_key]:thread_type [value]

Show all nodes ("thread_type" is internal id).

#### stats threads

**syntax**

    stats threads

**response**

    STAT [thread id]:type [value]
    STAT [thread id]:peer [value]
    STAT [thread id]:op [value]
    STAT [thread id]:uptime [value]
    STAT [thread id]:state [value]
    STAT [thread id]:info [value]
    STAT [thread id]:queue [value]

Show all threads.

### Command options

#### sync option

available on set/add/replace/append/prepend/incr/decr commands, like:

    set key1 0 0 3 sync

If this option is specified, response is send ''after'' replication is done (just opposite way of "noreply" option).

## Specification

### key length

Flare can accept keys more than 250 bytes.

### value length

Flare can accpet value more than 1M bytes (memcached returns "object too large").

### proxy identifier

Flare ''internally'' add proxy identifier w/ following format (to avoid infinite loop):

    <node name:port, node name:port,...>[command...]

for example:

    <flare.example.com:12121>get key1

