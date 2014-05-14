/**
 *	status.h
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#ifndef	__STATUS_H__
#define	__STATUS_H__

namespace gree {
namespace flare {

class status {
public:
	enum status_code {
		status_ok,
		status_ng,
	};

protected:
	status_code	_status_code;

public:
	status() : _status_code(status_ok) {};
	virtual ~status() {};

	inline void set_status_code(status_code s) { this->_status_code = s; };
	inline status_code get_status_code() { return this->_status_code; };

	virtual inline const char* get_detail_status() {
		switch (this->_status_code) {
		case status_ok:
			return "";
		case status_ng:
			return "unknown error";
		}
		return "";
	};
};

}	// namespace flare
}	// namespace gree

#endif	// __STATUS_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
