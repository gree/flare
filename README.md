# flare
flare is a distributed, and persistent key-value storage compatible with [memcached](http://memcached.org/), with several additional features (as follows):

- persistent storage (you can use flare as persistent memcached)
- pluggable storage
 - [Tokyo Cabinet](http://fallabs.com/tokyocabinet/)
 - [Kyoto Cabinet](http://fallabs.com/kyotocabinet/) (experimental)
- data replication (synchronous or asynchronous)
- data partitioning (automatically partitioned according to the number of master servers (transparent for clients)
- dynamic reconstruction, and partitioning (you can dynamically (I mean, without any service interruption) add slave servers and partition master servers)
- node monitoring and failover (if any server is down, the server is automatically isolated from active servers and another slave server is promoted to master server)
- request proxy (you can always get same result regardless of servers you connect to, so you can think of a flare cluster as one big key-value storage)
- over 256 bytes keys, and over 1M bytes values are available

flare is free software base on [GNU GENERAL PUBLIC LICENSE Version 2](http://www.gnu.org/licenses/gpl-2.0.html).

## Supported Operating Systems
flare is mainly developed under following platforms:

- Debian GNU/Linux (etch or later, both i386 and amd64)
- Mac OS X (Darwin 9.5.0, i386, amd64)
- FreeBSD
- other UNIX like OSs.

## Dependent library
### Run-time
- [boost](http://www.boost.org/)
- [Tokyo Cabinet](http://fallabs.com/tokyocabinet/)
- [Kyoto Cabinet](http://fallabs.com/kyotocabinet/) (optional)
- zlib
- libhashkit
- uuid

### Build-time
- [gcc](https://gcc.gnu.org/)
- autoconf
- automake
- libtool

## Install from source code on Ubuntu 14.04 (Trusty Tahr)
### Installation of depending packages
First, install depending packages by `apt-get`.
```
$ sudo apt-get install \
	git \
	locales \
	zlib1g-dev \
	build-essential \
	autoconf \
	automake \
	libtool \
	libboost-all-dev \
	libhashkit-dev \
	libtokyocabinet-dev \
	uuid-dev
```

### Installation of flare
Download source code, and compile it.
```
$ git clone https://github.com/gree/flare.git
$ cd flare
$ ./autogen.sh
$ ./configure
$ make
$ make check
$ sudo make install
```
If you want to optional packages, you should run `./configure` with options.  
**You can see available options by `./configure --help`.**

#### For example (when use Kyoto Cabinet):
First, you must install `libkyotocabinet-dev` in addition to depending packages.
```
$ sudo apt-get install libkyotocabinet-dev
```
And run `./configure` with `--with-kyotocabinet` option.
```
$ ./configure --with-kyotocabinet=/usr/include
```

## Create configuration file
Copy default configuration files from `etc`, and modify it.
```
$ sudo cp etc/flarei.conf /etc/
$ sudo cp etc/flared.conf /etc/
```

## Run
Now, you can run flare.
```
$ sudo /usr/local/bin/flarei -f /etc/flarei.conf --daemonize
$ sudo /usr/local/bin/flared -f /etc/flared.conf --daemonize
```
