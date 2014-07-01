/**
 *	status_index.h
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#ifndef	__STATUS_INDEX_H__
#define	__STATUS_INDEX_H__

#include "status.h"
#include "logger.h"

namespace gree {
namespace flare {

class status_index : public status {
public:
	enum index_status_code {
		index_status_ok,
		index_status_unknown_error,
	};

protected:
	index_status_code	_index_status_code;

public:
	status_index();
	virtual ~status_index();

	void set_index_status_code(index_status_code s);

	virtual inline const char* get_detail_status() {
		switch (this->_index_status_code) {
		case index_status_ok:
			return "";
		case index_status_unknown_error:
			return "unknown error";
		}
		return "";
	}

private:
	inline status_code _get_status_of(index_status_code s) {
		switch (s) {
		case index_status_ok:
			return status_ok;
		case index_status_unknown_error:
			return status_ng;
		}
		log_err("index_status_code is unknown value: %d", s);
		return status_ng;
	}
};

}	// namespace flare
}	// namespace gree

#endif	// __STATUS_INDEX_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
