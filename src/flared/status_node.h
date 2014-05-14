/**
 *	status_node.h
 *
 *	@author	Masanori Yoshimoto <masanori.yoshimoto@gree.net>
 *
 *	$Id$
 */
#ifndef	__STATUS_NODE_H__
#define	__STATUS_NODE_H__

#include "status.h"

namespace gree {
namespace flare {

class status_node : public status {
public:
	enum node_status_code {
		node_status_ok,
		node_status_storage_error,
		node_status_unknown_error,
	};

protected:
	node_status_code	_node_status_code;

public:
	status_node();
	virtual ~status_node();

	void set_node_status_code(node_status_code s);

	virtual inline const char* get_detail_status() {
		switch (this->_node_status_code) {
		case node_status_ok:
			return "";
		case node_status_storage_error:
			return "storage error";
		case node_status_unknown_error:
			return "unknown error";
		}
		return "";
	}

private:
	inline status_code _get_status_of(node_status_code s) {
		switch (s) {
		case node_status_ok:
			return status_ok;
		case node_status_storage_error:
			return status_ng;
		case node_status_unknown_error:
			return status_ng;
		}
	}
};

}	// namespace flare
}	// namespace gree

#endif	// __STATUS_NODE_H__
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
