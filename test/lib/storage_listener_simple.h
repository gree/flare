#ifndef STORAGE_LISTENER_SIMPLE_H
#define STORAGE_LISTENER_SIMPLE_H

#include <storage_listener.h>

namespace gree {
namespace flare {

class storage_listener_simple : public storage_listener {
	virtual void on_storage_error() {
		// do nothing
	}
};

}	// namespace flare
}	// namespace gree

#endif
