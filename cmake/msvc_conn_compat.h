// MSVC workaround: fix _close() symbol collision in nats conn.c.
//
// MSVC's CRT declares _close(int) as __declspec(dllimport) in <corecrt_io.h>.
// nats conn.c defines its own *static* _close(natsConnection*, ...) which MSVC
// rejects as a redefinition (C2371/C2491) even though it is static.
//
// A compiler-wide -D_close=<name> macro would rename _close everywhere,
// including inside the system header, causing the same conflict under a new name.
//
// This file is force-included (/FI) for conn.c only via CMakeLists.txt.
// Including <io.h> here causes corecrt_io.h to be processed with _close still
// holding its real CRT name. Include guards then prevent re-processing when
// conn.c pulls in the same header transitively, so the rename below only
// affects NATS's own static _close().
#include <io.h>
#define _close nats_conn_close_internal
