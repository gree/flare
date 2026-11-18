/*
 * Flare
 * --------------
 * Copyright (C) 2008-2014 GREE, Inc.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */
/**
 *	wal_archive.h
 *
 *	CONTINUOUS WAL ARCHIVE (docs/BACKUP_RESTORE.md, "WAL archive").
 *
 *	The hourly backup is a RocksDB checkpoint of one copy. The archive keeps
 *	that copy's WAL after the checkpoint, in short closed SEGMENT files, so a
 *	restore can replay the checkpoint forward to the last segment instead of
 *	stopping at the hour.
 *
 *	The replay is PHYSICAL: the batches are the copy's own WAL, written to a
 *	copy of the same database at the checkpoint's sequence number, in sequence
 *	order — what RocksDB's own recovery does. That is exact only while the
 *	batches come from the SAME physical copy, so every base and every segment
 *	carries the copy's identity (incarnation, history epoch, master id) and a
 *	segment is replayed only onto a base with the same identity, and only
 *	while the sequence numbers continue without a gap.
 *
 *	Pieces:
 *	  - base marker  (FLARE_BASE, written into every checkpoint by `backup`):
 *	    the checkpoint's exact sequence number and the copy's identity;
 *	  - segment file (written by `flared --wal-archive-follow`): a header with
 *	    the identity, then records LSN/count/time/size/crc + raw WriteBatch,
 *	    then a trailer — a file without its trailer is not a segment;
 *	  - replay       (`flared --wal-replay`): applies the contiguous run of
 *	    matching records after the base, optionally up to a time.
 */
#ifndef	WAL_ARCHIVE_H
#define	WAL_ARCHIVE_H

#include <stdint.h>
#include <signal.h>
#include <stdio.h>

#include <string>
#include <deque>
#include <utility>
#include <vector>

#include "connection.h"

using namespace std;

namespace gree {
namespace flare {
namespace wal_archive {

// The identity a base and its segments must share for a physical replay.
struct identity {
	string	incarnation;	// this physical copy (advances when it is replaced)
	string	epoch;			// the history it serves (advances on promotion, bulk ops)
	string	master_id;		// the lineage token
	bool operator==(const identity& o) const {
		return incarnation == o.incarnation && epoch == o.epoch && master_id == o.master_id;
	}
	bool operator!=(const identity& o) const { return !(*this == o); }
	bool complete() const {
		return !incarnation.empty() && !epoch.empty() && !master_id.empty();
	}
};

struct record {
	uint64_t	lsn;		// first sequence number of the batch
	uint32_t	count;		// sequence numbers the batch consumes
	int64_t		time_us;	// when the archiver had received it whole and CRC-verified
							// (wall clock) — NOT the source's commit time; the
							// time-bounded restore keeps batches with time_us <= until
	string		data;		// raw WriteBatch representation
	uint64_t last_lsn() const { return count == 0 ? lsn : lsn + count - 1; }
};

struct base {
	uint64_t	seq;		// the checkpoint holds exactly 1..seq
	identity	id;
	int64_t		time;		// unix seconds the checkpoint was taken
};

static const char* const kBaseFileName = "FLARE_BASE";
static const char* const kSegmentSuffix = ".wal";
// Written by replay into the database directory (see the resume rule).
static const char* const kReplayJournalFileName = "FLARE_REPLAY";

// {{{ base marker
string format_base(const base& b);
int parse_base(const string& text, base& out);
int write_base_file(const string& dir, const base& b);
int read_base_file(const string& dir, base& out);
// }}}

// {{{ segment files
// "<first lsn>-<last lsn>-<close time ms>.wal", zero padded so the names sort
// in sequence order.
string segment_name(const vector<record>& records, int64_t close_time_ms);
// Writes "<dir>/<name>.tmp", fsyncs it, renames it to "<dir>/<name>" and
// fsyncs the directory: a segment either exists complete or not at all.
int write_segment(const string& dir, const identity& id, const vector<record>& records,
	int64_t close_time_ms, string& out_path, string& err);
// Every record's CRC and the trailer are checked; anything short of a whole
// segment is an error (no partial result).
int read_segment(const string& path, identity& id, vector<record>& records, string& err);

// The same checks, one record at a time (the replay's memory must not grow
// with the archive). next(): 1 a record, 0 the end (trailer verified), -1 an
// error at that point.
class segment_reader {
public:
	segment_reader();
	~segment_reader();
	int open(const string& path, identity& id, string& err);
	int next(record& r, string& err);
	void close();
private:
	FILE*		_f;
	size_t		_n;
	uint64_t	_first;
	uint64_t	_end;
	bool		_done;
	bool _line(string& line);
	segment_reader(const segment_reader&);
	segment_reader& operator=(const segment_reader&);
};
// }}}

// {{{ replay planning (pure)
struct replay_plan {
	vector<const record*>	apply;		// in order, contiguous after base_seq
	uint64_t	last_lsn;				// position after the plan (base_seq if empty)
	int64_t		last_time_us;			// receive time of the last planned record
	bool		gap;					// a later record exists but does not continue
	uint64_t	gap_expected;			// the lsn that was missing
	uint64_t	gap_found;				// the next lsn that was available
	bool		stopped_by_until;		// a continuing record was later than until
	bool		conflict;				// two different batches claimed one lsn
	replay_plan(): last_lsn(0), last_time_us(0), gap(false), gap_expected(0),
		gap_found(0), stopped_by_until(false), conflict(false) {}
};
// `records` need not be sorted or unique (segments may overlap after an
// archiver restart); equal duplicates are folded, different ones stop the
// plan (conflict). until_us <= 0 means no time bound.
replay_plan plan_replay(uint64_t base_seq, const vector<record>& records, int64_t until_us);
// }}}

// {{{ follower (`flared --wal-archive-follow`)
class follower {
public:
	enum exit_code {
		exit_ok = 0,			// stopped by a signal, pending records flushed
		exit_usage = 2,
		exit_io = 3,			// could not write a segment
		exit_needs_base = 10,	// this identity can never continue: take a new base
	};
	struct options {
		string		host;
		int			port;
		identity	id;
		uint64_t	from_lsn;			// last sequence already archived (or the base)
		string		out_dir;
		int			segment_seconds;	// close a non-empty segment this long after its first record
		uint64_t	segment_bytes;		// ... or when it holds this many bytes
		int			poll_usec;			// idle poll interval
		uint64_t	max_batches;		// slice bounds sent to the source
		uint64_t	max_bytes;
		options(): port(0), from_lsn(0), segment_seconds(30), segment_bytes(64ULL << 20),
			poll_usec(500000), max_batches(1000), max_bytes(16ULL << 20) {}
	};

	// What one response produced.
	enum response_result {
		response_ok = 0,
		response_transport,		// connection broke: reconnect, keep the position
		response_retry,			// source cannot serve now (restored, no epoch...): retry later
		response_needs_base,	// position/identity can never be served again
	};
	// Reads one repl_sync_wal response. Appends the batches that continue
	// `cursor` (updating it); `reason` names a non-ok result.
	static response_result read_response(shared_connection c, const identity& id,
		uint64_t& cursor, vector<record>& out, bool& more, uint64_t& server_latest,
		string& reason);
	static response_result classify_server_error(const string& body);

	explicit follower(const options& o);
	int run(volatile sig_atomic_t* stop);

	// Files the driver reads, in out_dir.
	static const char* const kPositionFile;		// "<incarnation> <epoch> <master_id> <lsn> <unix>"
	static const char* const kNeedsBaseFile;	// "<reason> <lsn> <unix>"
	static const char* const kSyncedFile;		// "<unix ms>": all the source had then is in closed segments

private:
	options			_o;
	vector<record>	_pending;
	uint64_t		_pending_bytes;
	uint64_t		_cursor;
	std::deque<std::pair<int64_t, uint64_t> >	_observed;	// (asked at, source latest)
	int64_t			_synced_us;
	int _close_segment(string& err);
	void _note_synced();
	void _write_position();
};
// }}}

// {{{ replay (`flared --wal-replay`)
// Applies the archived segments under seg_dir onto the RocksDB directory
// db_dir, which must hold the checkpoint FLARE_BASE describes. Writes a
// one-line summary to `report`. A re-run after an interruption continues only
// the same chain (the FLARE_REPLAY journal, see the resume rule in the .cc).
// Return: 0 replayed everything the archive holds
// for this base (up to the time bound), 4 replayed only a part of it — a gap,
// a conflict, or a corrupt segment holding later history (the contiguous part
// IS applied; the caller decides whether to use it), 1 the database could not
// be opened or written, 3 the base marker is missing or does not describe
// this database.
int replay(const string& db_dir, const string& seg_dir, int64_t until_us, FILE* report);
// }}}

}	// namespace wal_archive
}	// namespace flare
}	// namespace gree

#endif	// WAL_ARCHIVE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 noexpandtab autoindent
