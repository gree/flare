/**
 *	binary_network_mapping.h
 *
 *	@author	Benjamin Surma <benjamin.surma@gree.net>
 *
 *	$Id$
 */

#ifndef BINARY_NETWORK_MAPPING_H
#define BINARY_NETWORK_MAPPING_H

#include "binary_header.h"
#include "connection.h"
#include "htonll.h"
#include "string.h"

#include <boost/static_assert.hpp>
#include <boost/type_traits.hpp>

namespace gree {
namespace flare {

template<typename T, binary_header::magic magic> class network_mapping
{
public:
	// Default constructors
	network_mapping(binary_header::opcode);
	network_mapping(shared_connection);
	// Copy constructor
	network_mapping(const network_mapping&);
	// Destructor
	~network_mapping();

	int push_back(shared_connection) const;

	const char* get_raw_data() const;
	size_t get_raw_size() const;

private:
	char* const _buffer;
	// Disable assignment
	network_mapping& operator=(const network_mapping&);

protected:
	T* const _mapping;
#if defined __GNUC__ && \
	(__GNUC__ > 4 || (__GNUC__ == 4 && __GNUC_MINOR__ > 5))
	BOOST_STATIC_ASSERT(boost::is_pod<T>::value);
#endif
};

template<typename T, binary_header::magic M>
network_mapping<T, M>::network_mapping(binary_header::opcode opcode):
	_buffer(new char[sizeof(T)]),
	_mapping(reinterpret_cast<T*>(_buffer)) {
	memset(_buffer, 0, sizeof(T));
	_mapping->magic = M;
	_mapping->opcode = opcode;
}

template<typename T, binary_header::magic M>
network_mapping<T, M>::network_mapping(shared_connection c):
	_buffer(NULL),
	_mapping(NULL) {
	char* buffer;
	if (c->readsize(sizeof(T), &buffer) < 0) {
		throw -1;
	}
	const_cast<char*&>(_buffer) = buffer;
	const_cast<T*&>(_mapping) = reinterpret_cast<T*>(_buffer);
	if (_mapping->magic != M) {
		c->push_back(_buffer, sizeof(T));
		delete[] _buffer;
		throw -1;
	}
}

template<typename T, binary_header::magic M>
network_mapping<T, M>::network_mapping(const network_mapping& c):
	_buffer(new char[sizeof(T)]),
	_mapping(reinterpret_cast<T*>(_buffer)) {
	memcpy(_buffer, c._buffer, sizeof(T));
}

template<typename T, binary_header::magic M>
network_mapping<T, M>::~network_mapping() {
	delete[] _buffer;
}

template<typename T, binary_header::magic M>
int network_mapping<T, M>::push_back(shared_connection c) const {
	return c->push_back(_buffer, sizeof(T));
}

template<typename T, binary_header::magic M>
const char* network_mapping<T, M>::get_raw_data() const {
	return _buffer;
}

template<typename T, binary_header::magic M>
size_t network_mapping<T, M>::get_raw_size() const {
	return sizeof(T);
}

#define DEFINE_UINT8_GETTER(field) uint8_t get_##field() const { \
	return _mapping->field; \
}

#define DEFINE_UINT16_GETTER(field) uint16_t get_##field() const { \
	return ntohs(_mapping->field); \
}

#define DEFINE_UINT32_GETTER(field) uint32_t get_##field() const { \
	return ntohl(_mapping->field); \
}

#define DEFINE_UINT64_GETTER(field) uint64_t get_##field() const { \
	return ntohll(_mapping->field); \
}

#define DEFINE_UINT8_SETTER(field) void set_##field(uint8_t value) const { \
	_mapping->field = value; \
}

#define DEFINE_UINT16_SETTER(field) void set_##field(uint16_t value) const { \
	_mapping->field = htons(value); \
}

#define DEFINE_UINT32_SETTER(field) void set_##field(uint32_t value) const { \
	_mapping->field = htonl(value); \
}

#define DEFINE_UINT64_SETTER(field) void set_##field(uint64_t value) const { \
	_mapping->field = htonll(value); \
}

} // namespace flare
} // namespace gree

#endif//BINARY_NETWORK_MAPPING_H

// vim: foldmethod=marker tabstop=2 shiftwidth=2 autoindent
