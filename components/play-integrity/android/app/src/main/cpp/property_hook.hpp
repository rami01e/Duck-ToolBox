/* Derived from Play Integrity Fork, osm0sis, chiteroman and contributors.
 * Source: https://github.com/osm0sis/PlayIntegrityFork/tree/23ec56c2440c4fd1a5e893a23ef7861d6366a828
 * SPDX-License-Identifier: GPL-3.0-only
 * Modified 2026-10-23: independent engine packaging, bounded configuration and runtime operations.
 * Modified 2026-10-30: x86_64 support. The interception moved from ShadowHook's inline hook
 * (arm32/arm64 only) to ByteHook's PLT hooking (all four ABIs), so the hook signatures are
 * declared ABI-independent at namespace scope and the classic __system_property_get import
 * is hooked next to __system_property_read_callback.
 */
#pragma once
#include "settings.hpp"
#include <sys/system_properties.h>
namespace pif {
using PropertyCallback=void (*)(void *,const char *,const char *,uint32_t);
using PropertyRead=void (*)(const prop_info *,PropertyCallback,void *);
using PropertyFind=const prop_info *(*)(const char *);
using PropertyGet=int (*)(const char *,char *);
class PropertyHook {
public:
    bool install(const Settings &settings);
private:
    struct Context { const PropertyHook *owner; PropertyCallback callback; void *cookie; };
    static void read(const prop_info *,PropertyCallback,void *);
    static int get(const char *,char *);
    static void copyValue(void *,const char *,const char *,uint32_t);
    static void modify(void *,const char *,const char *,uint32_t);
    std::map<std::string,std::string> properties;
    PropertyRead original=nullptr;
    PropertyFind originalFind=nullptr;
    int logLevel=0;
};
}
