# Flare Build Guide

## Overview

Flare supports two build modes:
1. **Legacy Mode** (default): Uses Tokyo Cabinet/Kyoto Cabinet storage engines
2. **RocksDB Mode**: Adds RocksDB storage engine with WAL-based incremental replication

Both modes maintain full backward compatibility with existing deployments.

## Quick Start

### Legacy Build (Default)

```bash
./autogen.sh
./configure
make -j$(nproc)
make check
sudo make install
```

### RocksDB Build

```bash
./autogen.sh
./configure --with-rocksdb=/path/to/rocksdb
make -j$(nproc)
make check
sudo make install
```

## Build Requirements

### Common Dependencies
- autoconf >= 2.59
- automake >= 1.9
- libtool >= 1.5
- gcc/g++ with C++11 support
- boost >= 1.41 (system, thread, serialization, regex, program_options)
- zlib
- libmemcached
- Tokyo Cabinet
- libuuid (Linux) or libossp-uuid (macOS)
- cutter (for tests)

### Additional for RocksDB Mode
- RocksDB >= 6.0 (tested with 10.5.1)
- RocksDB dependencies:
  - bzip2
  - lz4
  - snappy
  - zstd

## Configuration Options

### Storage Backends

```bash
# Tokyo Cabinet only (default)
./configure

# With Kyoto Cabinet
./configure --with-kyotocabinet=/path/to/kyotocabinet

# With RocksDB
./configure --with-rocksdb=/path/to/rocksdb

# With both Kyoto Cabinet and RocksDB
./configure --with-kyotocabinet=/path/to/kyotocabinet \
            --with-rocksdb=/path/to/rocksdb
```

### Other Options

```bash
# Enable ZooKeeper coordination
./configure --with-zookeeper=/path/to/zookeeper

# Install to custom prefix
./configure --prefix=/usr/local/flare

# Debug build
./configure CXXFLAGS="-g -O0"
```

## Build Verification

### Check Compiled Features

```bash
# List storage backends compiled
nm src/flared/flared | grep -E "(storage_|rocksdb)"

# Verify RocksDB support
ldd src/flared/flared | grep rocksdb
```

### Run Tests

```bash
# Run all tests
make check

# Run specific test suite
cd test/lib
./.libs/test_storage_rocksdb.so  # RocksDB tests (requires RocksDB build)
./.libs/test_storage_tch.so      # Tokyo Cabinet tests
```

## Nix Builds

### Using Nix Flakes

```bash
# Build legacy version (default)
nix build .#flare

# Build RocksDB version
nix build .#flare-rocksdb

# Run tests for legacy version
nix build .#test-flare

# Run tests for RocksDB version
nix build .#test-flare-rocksdb

# Enter development shell
nix develop
```

### Traditional Nix

```bash
# Build default
nix-build -A flare

# Build with RocksDB
nix-build -A flare-rocksdb
```

## CI/CD Integration

### GitHub Actions

The project uses GitHub Actions for continuous integration with a build matrix:

- **test-legacy**: Builds and tests without RocksDB (backward compatibility)
- **test-rocksdb**: Builds and tests with RocksDB (new features)

Both jobs run on every push and pull request.

### Local CI Testing

```bash
# Test legacy build
nix build .#test-flare -L

# Test RocksDB build
nix build .#test-flare-rocksdb -L
```

## Installation

### System-wide Installation

```bash
sudo make install
```

Default installation paths:
- Binaries: `/usr/local/bin/flared`, `/usr/local/bin/flarei`
- Libraries: `/usr/local/lib/libflare.*`
- Headers: `/usr/local/include/flare/`

### Custom Installation

```bash
./configure --prefix=/opt/flare
make install
```

## Runtime Configuration

### Choosing Storage Engine

Edit `/etc/flare.ini` or pass via command line:

```ini
[data]
# Legacy: Tokyo Cabinet Hash (default)
data-type = tch

# Legacy: Tokyo Cabinet B+ Tree
data-type = tcb

# Kyoto Cabinet (if compiled with --with-kyotocabinet)
data-type = kch

# RocksDB (if compiled with --with-rocksdb)
data-type = rocksdb
```

### RocksDB-Specific Configuration

```ini
[data]
data-type = rocksdb
data-dir = /var/lib/flare/data

# Memory management
storage-cache-size = 512        # Block cache in MB (default: 512)
storage-write-buffer = 64       # MemTable size in MB (default: 64)
storage-max-write-buffers = 3   # Number of MemTables (default: 3)

# WAL retention for replication
storage-wal-ttl = 86400        # WAL TTL in seconds (default: 24h)
storage-wal-size-limit = 10240 # WAL size limit in MB (default: 10GB)
```

## Troubleshooting

### RocksDB Not Found

```bash
# Verify RocksDB is installed
pkg-config --exists rocksdb && echo "Found" || echo "Not found"

# Get RocksDB paths
pkg-config --cflags --libs rocksdb

# Specify paths explicitly
./configure --with-rocksdb=/usr/local \
            CPPFLAGS="-I/usr/local/include" \
            LDFLAGS="-L/usr/local/lib"
```

### Missing Dependencies

```bash
# Debian/Ubuntu
sudo apt-get install autoconf automake libtool pkg-config \
                     libboost-all-dev zlib1g-dev libmemcached-dev \
                     libtokyocabinet-dev uuid-dev

# For RocksDB
sudo apt-get install librocksdb-dev

# macOS (Homebrew)
brew install autoconf automake libtool pkg-config boost \
             zlib libmemcached tokyocabinet ossp-uuid

# For RocksDB
brew install rocksdb
```

### Test Failures

```bash
# Run tests with verbose output
make check VERBOSE=1

# Run specific test
cd test/lib
cutter -v v ./.libs/test_storage_rocksdb.so

# Check test logs
cat test/test-suite.log
```

## Upgrade Path

### From Legacy to RocksDB

1. **Backup**: Dump all data using legacy storage
2. **Rebuild**: Compile with RocksDB support
3. **Configure**: Update flare.ini to use `data-type = rocksdb`
4. **Restore**: Use cluster replication to sync data

### RocksDB Replication Modes

The system automatically selects the best replication mode:

1. **WAL Delta Sync** (fastest): Master and slave both have RocksDB
2. **Full Dump** (fallback): When WAL is unavailable or LSN purged
3. **Legacy Replication**: When either side doesn't have RocksDB

## Performance Tuning

### RocksDB Configuration

```ini
# High-throughput workloads
storage-cache-size = 2048
storage-write-buffer = 128
storage-max-write-buffers = 4

# Memory-constrained environments
storage-cache-size = 256
storage-write-buffer = 32
storage-max-write-buffers = 2

# Long replication lag tolerance
storage-wal-ttl = 604800      # 7 days
storage-wal-size-limit = 51200 # 50GB
```

## Development

### Building from Git

```bash
git clone https://github.com/gree/flare-rocksdb-2.git
cd flare-rocksdb-2
./autogen.sh
./configure --with-rocksdb
make
```

### Code Changes

After modifying configure.ac or Makefile.am:

```bash
./autogen.sh
./configure [options]
make clean
make
```

## Support

- Issues: https://github.com/gree/flare-rocksdb-2/issues
- Original Flare: https://github.com/gree/flare

## License

GNU General Public License v2.0 - see LICENSE file for details.
