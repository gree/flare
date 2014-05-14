/**
 *	show_node.h
 *
 *	@author	Yuya YAGUCHI <yuya.yaguchi@gree.net>
 *
 *	$Id$
 */
#ifndef SHOW_NODE_H
#define SHOW_NODE_H

#include <vector>
#include <string>

using namespace std;

namespace gree {
namespace flare {

class show_node {
public:
	static vector<string> lines();

protected:
	static string index_servers_line();
};

}	// namespace flare
}	// namespace gree

#endif // SHOW_NODE_H
// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
