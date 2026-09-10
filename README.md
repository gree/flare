# flare

This fork is upstream flare **plus a Kubernetes operator**, and the two are
designed together. If you have landed here to review the design, start with
[docs/REVIEW-GUIDE.md](docs/REVIEW-GUIDE.md).

## What is different from upstream

Upstream flare is a memcached-compatible store whose cluster topology is
owned by a separate index server, `flarei`. Here:

- **The operator replaces flarei.** It speaks the same TCP protocol to
  flared, so flared is unmodified in that respect, but topology decisions —
  who is master, who reconstructs, who leaves the serving set — are made by
  a reconciler that reads Kubernetes and writes the node map.
- **The operator is written in Lean 4**, with the decisions isolated in pure
  functions and the important ones carried by machine-checked proofs (151
  theorems; elaborating the library checks them). The properties that matter
  are safety bounds — at most one master per partition survives the commit
  path — not liveness.
- **RocksDB is the production storage backend**, with WAL-based
  reconstruction, snapshot bootstrap, and off-cluster backup to object
  storage.
- **Deployment is a Helm chart** that owns the CRDs, the operator, the
  StatefulSet, backup CronJobs, and monitoring.

Everything below the "Upstream flare" heading is the original project
documentation and still describes the protocol and storage semantics.

## Layout

| Path | What lives there |
|---|---|
| `src/` | flared and flarei (C++). Storage backends, replication, the wire protocol |
| `flare_operator/FlareOperator/StateMachine/` | The reconciler as pure functions, and the proofs about them |
| `flare_operator/FlareOperator/Main.lean` | The IO shell: fetch state, run the machine, apply effects, export metrics |
| `flare_operator/FlareOperator/Server/` | The flarei-compatible TCP surface |
| `flare_operator/FlareOperator/E2E/` | 26 end-to-end suites, run against a kind cluster |
| `helm/flare-operator/` | The chart: CRDs, operator, cluster StatefulSet, backup, alerts |
| `docs/` | Design, operations and hazard analysis — see the map below |

## Where to read what

**Current** — maintained, and checked against the code:

| Document | Read it when |
|---|---|
| [docs/REVIEW-GUIDE.md](docs/REVIEW-GUIDE.md) | You are reviewing the design or arriving for the first time |
| [docs/STPA-node-state.md](docs/STPA-node-state.md) | You need to know when a node leaves the serving set, what detects each failure, and which hazards are still uncovered |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | An alert fired, or you are about to upgrade, reseed or migrate a cluster |
| [docs/BACKUP_RESTORE.md](docs/BACKUP_RESTORE.md) | Backups, restores, and what replication does *not* protect against |
| [CONTRIBUTING.md](CONTRIBUTING.md) | You are about to change something |

**Historical** — accurate when written, not maintained since; useful for
intent, not as a description of today's code:

| Document | Written for |
|---|---|
| [docs/review-overview.md](docs/review-overview.md), [docs/review-pr140-pr142.md](docs/review-pr140-pr142.md) | The original operator and RocksDB-backend review (PR #140 / #142, mid-2026) |
| [docs/design-review.md](docs/design-review.md) | A one-hour design review of the operator and WAL replication |
| [docs/design-wal-cluster-replication.md](docs/design-wal-cluster-replication.md) | A design that was **never implemented** — cluster replication still uses the dump path it describes replacing |
| [docs/oss-bug-analysis.md](docs/oss-bug-analysis.md), [docs/e2e-test-issues.md](docs/e2e-test-issues.md) | Point-in-time notes from early 2026 |

---

# Upstream flare

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

## Install flare via Nix on Ubuntu or MacOS

We experimentally support development with nix package manager.

### Installation of flare

Just type following commands.

```
# Install nix package manager
$ curl -L https://nixos.org/nix/install | sh
# Install flare
$ nix profile install github:gree/flare
```

### Development of flare via Nix

```
# Clone source code
$ git clone git@github.com:gree/flare.git

# Enter a development environment of nix
$ nix develop

# Build source codes
$ ./autogen.sh
$ ./configure
$ make
$ make test
```

## Build Debian Package with Docker

```bash
# Build Debian package
$ ./build-debian-docker.sh

# Install the package
$ sudo dpkg -i debian-packages/kvs-flare*.deb
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
