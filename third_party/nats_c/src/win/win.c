// Copyright 2015-2018 The NATS Authors
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Windows-only implementations of POSIX functions not available in MSVC.
// On Unix, nats_asprintf and nats_strcasestr are macro aliases (n-unix.h).
// On Windows, n-win.h declares them as real functions — defined here.

#include "../natsp.h"

#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

int
nats_asprintf(char **newStr, const char *fmt, ...)
{
    va_list args;
    int     len;
    char    *str;

    va_start(args, fmt);
    len = _vscprintf(fmt, args);
    va_end(args);

    if (len < 0)
        return -1;

    str = malloc((size_t)len + 1);
    if (str == NULL)
        return -1;

    va_start(args, fmt);
    len = vsnprintf(str, (size_t)len + 1, fmt, args);
    va_end(args);

    *newStr = str;
    return len;
}

char*
nats_strcasestr(const char *haystack, const char *needle)
{
    size_t needleLen   = strlen(needle);
    size_t haystackLen = strlen(haystack);
    size_t i;

    if (needleLen == 0)
        return (char *)haystack;

    for (i = 0; i + needleLen <= haystackLen; i++)
    {
        if (_strnicmp(haystack + i, needle, needleLen) == 0)
            return (char *)(haystack + i);
    }
    return NULL;
}
