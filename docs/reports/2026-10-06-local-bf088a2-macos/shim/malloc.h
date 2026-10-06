/* LOCAL macOS BUILD SHIM ONLY (not part of the repository): glibc's
 * mallinfo2 is unavailable on macOS; stats report zeros here. */
#ifndef LOCAL_SHIM_MALLOC_H
#define LOCAL_SHIM_MALLOC_H
#include <stdlib.h>
#include <string.h>
struct mallinfo2 { size_t arena, ordblks, smblks, hblks, hblkhd, usmblks, fsmblks, uordblks, fordblks, keepcost; };
static inline struct mallinfo2 mallinfo2(void) { struct mallinfo2 m; memset(&m, 0, sizeof(m)); return m; }
#endif
