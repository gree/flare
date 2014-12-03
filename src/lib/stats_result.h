/**
*	@author	Yuya YAGUCHI <yuya.yaguchi@gree.net>
*
*	$Id$
*/
#ifndef	STATS_RESULT_H
#define	STATS_RESULT_H

#include <string>
#include <vector>

class stats_result {
public:
	string name;
	string value;
};

class stats_results : public vector<stats_result> {
public:
	stats_results::const_iterator find_by_name(string name) const {
		const_iterator iter = this->begin();
		while (iter != this->end()) {
			if (iter->name == name) {
				return iter;
			}
			++iter;
		}
		return this->end();
	}
};

#endif