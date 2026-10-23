/**
 *	op_authority.cc
 *
 *	implementation of gree::flare::op_authority (see the header)
 */
#include "op_authority.h"
#include "write_fence.h"
#include "connection_tcp.h"

namespace gree {
namespace flare {

namespace {
bool parse_u64(const char* s, uint64_t& v) {
	if (s[0] == '\0' || strlen(s) > 19) {
		return false;
	}
	uint64_t r = 0;
	for (const char* p = s; *p; p++) {
		if (*p < '0' || *p > '9') {
			return false;
		}
		r = r * 10 + static_cast<uint64_t>(*p - '0');
	}
	v = r;
	return true;
}
}

op_authority::op_authority(shared_connection c):
		op(c, "authority"),
		_partition(0), _a(0), _b(0), _c(0), _d(0), _e(0) {
}

op_authority::~op_authority() {
}

int op_authority::_parse_text_server_parameters() {
	char* p;
	if (this->_connection->readline(&p) < 0) {
		return -1;
	}
	vector<string> w;
	int n = 0;
	for (;;) {
		char q[BUFSIZ];
		const int k = util::next_word(p + n, q, sizeof(q));
		if (q[0] == '\0') {
			break;
		}
		w.push_back(q);
		n += k;
		if (w.size() > 64) {
			delete[] p;
			return -1;
		}
	}
	delete[] p;
	if (w.empty()) {
		return -1;
	}
	this->_action = w[0];
	size_t need = 0;		// numeric arguments after the verb (partition first)
	size_t words = 0;		// then this many identity words (boot id, copy id)
	if (this->_action == "promise") {
		need = 5;
	} else if (this->_action == "members") {
		need = 5;
	} else if (this->_action == "solo" || this->_action == "floor") {
		need = 3;
	} else if (this->_action == "prepare" || this->_action == "commit" || this->_action == "cancel") {
		// <p> <intent> <term_next> <generation> <boot_id> <copy_id>: the complete scope
		need = 4;
		words = 2;
	} else if (this->_action == "first") {
		// <p> <boot_id> <copy_id>: a fresh first build was proven for this incarnation
		need = 1;
		words = 2;
	} else if (this->_action == "status") {
		need = 1;
	} else {
		return -1;
	}
	if (w.size() < 1 + need + words || (this->_action != "members" && w.size() != 1 + need + words)) {
		return -1;
	}
	uint64_t v[5] = { 0, 0, 0, 0, 0 };
	for (size_t i = 0; i < need; i++) {
		if (!parse_u64(w[1 + i].c_str(), v[i])) {
			return -1;
		}
	}
	if (v[0] > 0xffffffffULL) {
		return -1;
	}
	this->_partition = static_cast<uint32_t>(v[0]);
	this->_a = v[1]; this->_b = v[2]; this->_c = v[3]; this->_d = v[4];
	for (size_t i = 0; i < words; i++) {
		const string& s = w[1 + need + i];
		if (s.size() > 128) {
			return -1;
		}
		this->_ids.push_back(s);
	}
	if (this->_action == "members") {
		for (size_t i = 1 + need; i < w.size(); i++) {
			this->_keys.push_back(w[i]);
		}
		if (this->_keys.empty()) {
			return -1;
		}
	}
	return 0;
}

int op_authority::_send_status(uint32_t partition) {
	const write_promise::status s = write_promise::get_status(partition);
	string idboot, idcopy;
	write_promise::identity(idboot, idcopy);
	static const char* names[] = { "following", "preparing", "committed", "promoted" };
	uint64_t ft = 0, fg = 0;
	const bool have_floor = write_fence::authority_floor(partition, ft, fg);
	write_promise::members m;
	const bool have_m = write_promise::get_members(partition, m);		// re-binds a membership to a changed identity first
	uint64_t gt = 0, gg = 0, rem = 0;
	bool gsolo = false;
	const bool grant = write_fence::authority_info(partition, gt, gg, gsolo, rem);
	string succ;
	for (size_t i = 0; i < m.successors.size(); i++) {
		succ += (i ? "," : "") + m.successors[i];
	}
	char line[2048];
	snprintf(line, sizeof(line),
		"STAT authority_enabled %d\r\nSTAT authority_refused %llu\r\n"
		"STAT promise_state %s\r\nSTAT promise_intent %llu\r\nSTAT promise_have %d\r\n"
		"STAT promise_remaining_ms %llu\r\nSTAT promise_promotable %d\r\n"
		"STAT promise_term_next %llu\r\nSTAT promise_gen %llu\r\nSTAT promise_boot %s\r\nSTAT promise_copy %s\r\n"
		"STAT identity_boot %s\r\nSTAT identity_copy %s\r\nSTAT members_boot %s\r\nSTAT members_copy %s\r\n"
		"STAT floor_term %llu\r\nSTAT floor_gen %llu\r\nSTAT floor_set %d\r\n"
		"STAT members_mode %s\r\nSTAT members_term %llu\r\nSTAT members_gen %llu\r\nSTAT members_successors %s\r\n"
		"STAT grant_valid %d\r\nSTAT grant_term %llu\r\nSTAT grant_gen %llu\r\nSTAT grant_solo %d\r\nSTAT grant_remaining_ms %llu\r\n",
		write_promise::enabled() ? 1 : 0, static_cast<unsigned long long>(write_fence::authority_refused()),
		names[s.st], static_cast<unsigned long long>(s.intent), s.have_promise ? 1 : 0,
		static_cast<unsigned long long>(s.remaining_ms), s.promotable ? 1 : 0,
		static_cast<unsigned long long>(s.term_next), static_cast<unsigned long long>(s.generation), s.boot.c_str(), s.copy.c_str(),
		idboot.empty() ? "-" : idboot.c_str(), idcopy.empty() ? "-" : idcopy.c_str(), have_m ? m.boot.c_str() : "-", have_m ? m.copy.c_str() : "-",
		static_cast<unsigned long long>(ft), static_cast<unsigned long long>(fg), have_floor ? 1 : 0,
		!have_m ? "none" : (m.solo ? "solo" : "replicated"),
		static_cast<unsigned long long>(m.term), static_cast<unsigned long long>(m.generation), succ.empty() ? "-" : succ.c_str(),
		grant ? 1 : 0, static_cast<unsigned long long>(gt), static_cast<unsigned long long>(gg), gsolo ? 1 : 0,
		static_cast<unsigned long long>(rem / 1000000ULL));
	this->_connection->write(line, strlen(line));
	return this->_send_result(result_end);
}

int op_authority::_run_server() {
	string why;
	write_promise::status s;
	write_promise::scope sc;
	if (this->_action == "prepare" || this->_action == "commit" || this->_action == "cancel") {
		sc.intent = this->_a;
		sc.term_next = this->_b;
		sc.generation = this->_c;
		sc.boot = this->_ids[0];
		sc.copy = this->_ids[1];
	}
	if (this->_action == "promise") {
		// members of the line: term, gen, ttl_ms, nonce
		if (!write_promise::promise(this->_partition, this->_a, this->_b, this->_c, why)) {
			return this->_send_result(result_server_error, why.c_str());
		}
		char line[96];
		snprintf(line, sizeof(line), "PROMISED %llu\r\n", static_cast<unsigned long long>(this->_d));
		this->_connection->write(line, strlen(line));
		return 0;
	} else if (this->_action == "members") {
		if (!write_promise::set_members(this->_partition, this->_a, this->_b, this->_c, this->_d, this->_keys, why)) {
			return this->_send_result(result_server_error, why.c_str());
		}
		log_notice("write authority: members of partition %u set (term=%llu gen=%llu, %u successors)", this->_partition,
			static_cast<unsigned long long>(this->_a), static_cast<unsigned long long>(this->_b), static_cast<unsigned>(this->_keys.size()));
	} else if (this->_action == "solo") {
		if (!write_promise::set_solo(this->_partition, this->_a, this->_b, why)) {
			return this->_send_result(result_server_error, why.c_str());
		}
		log_notice("write authority: solo grant for partition %u (term=%llu gen=%llu)", this->_partition,
			static_cast<unsigned long long>(this->_a), static_cast<unsigned long long>(this->_b));
	} else if (this->_action == "first") {
		if (!write_promise::allow_first_build(this->_partition, this->_ids[0], this->_ids[1], why)) {
			return this->_send_result(result_server_error, why.c_str());
		}
		log_notice("write authority: a fresh first build of partition %u is allowed once for this incarnation", this->_partition);
	} else if (this->_action == "floor") {
		if (!write_promise::set_floor(this->_partition, this->_a, this->_b, why)) {
			return this->_send_result(result_server_error, why.c_str());
		}
	} else if (this->_action == "prepare") {
		if (!write_promise::prepare(this->_partition, sc, s, why)) {
			return this->_send_result(result_server_error, why.c_str());
		}
		log_notice("write authority: PREPARING partition %u for intent %llu (promises stop)", this->_partition, static_cast<unsigned long long>(this->_a));
	} else if (this->_action == "commit") {
		if (!write_promise::commit(this->_partition, sc, s, why)) {
			return this->_send_result(result_server_error, why.c_str());
		}
		log_notice("write authority: intent %llu COMMITTED for partition %u", static_cast<unsigned long long>(this->_a), this->_partition);
	} else if (this->_action == "cancel") {
		if (!write_promise::cancel(this->_partition, sc, s, why)) {
			return this->_send_result(result_server_error, why.c_str());
		}
		log_notice("write authority: intent %llu cancelled for partition %u (promises resume)", static_cast<unsigned long long>(this->_a), this->_partition);
	}
	return this->_send_status(this->_partition);
}

bool op_authority::request_promise(const string& host, int port, uint32_t partition, uint64_t term, uint64_t generation,
		uint64_t ttl_ms, uint64_t nonce, int timeout_ms, string& why) {
	connection_tcp* t = new connection_tcp(host, port);
	t->set_connect_timeout_ms(timeout_ms);
	t->set_connect_retry_limit(1);
	t->set_read_timeout(timeout_ms);
	shared_connection c(t);
	if (c->open() < 0) {
		why = "connect failed";
		return false;
	}
	t->set_deadline_from_now(timeout_ms);
	char req[256];
	snprintf(req, sizeof(req), "authority promise %u %llu %llu %llu %llu", partition, static_cast<unsigned long long>(term),
		static_cast<unsigned long long>(generation), static_cast<unsigned long long>(ttl_ms), static_cast<unsigned long long>(nonce));
	if (c->writeline(req) < 0) {
		why = "send failed";
		return false;
	}
	char* p = NULL;
	if (c->readline(&p) < 0) {
		why = "no reply";
		return false;
	}
	char want[64];
	snprintf(want, sizeof(want), "PROMISED %llu", static_cast<unsigned long long>(nonce));
	const bool ok = strncmp(p, want, strlen(want)) == 0 && (p[strlen(want)] == '\r' || p[strlen(want)] == '\n' || p[strlen(want)] == '\0');
	if (!ok) {
		why = string("refused: ") + p;
	}
	delete[] p;
	c->close();
	return ok;
}

}	// namespace flare
}	// namespace gree
