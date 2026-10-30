/* Derived from Play Integrity Fork, osm0sis, chiteroman and contributors.
 * Source: https://github.com/osm0sis/PlayIntegrityFork/tree/23ec56c2440c4fd1a5e893a23ef7861d6366a828
 * SPDX-License-Identifier: GPL-3.0-only
 * Modified 2026-10-23: independent engine packaging, bounded configuration and runtime operations.
 * Modified 2026-10-30: x86_64 support. ShadowHook provides inline hooking for arm32/arm64 only,
 * so the property interception now runs on ByteHook (MIT, https://github.com/bytedance/bhook),
 * which supports armeabi-v7a, arm64-v8a, x86 and x86_64. ByteHook rewrites PLT/GOT entries and
 * cannot patch callers inside libc itself, so the caller-side __system_property_get import is
 * hooked next to __system_property_read_callback; together they cover every cross-module
 * property read in the injected process with the same substitution semantics as the upstream
 * inline hook. Real implementations are resolved once with dlsym and called through their
 * absolute addresses, so no hooked PLT entry is re-entered. In ByteHook's AUTOMATIC mode every
 * hooked call passes a per-thread trampoline frame, so both replacements pop the frame before
 * returning (the macro is mode-guarded and a no-op under a MANUAL initialization).
 */
#include "property_hook.hpp"
#include "bytehook.h"
#include <android/log.h>
#include <atomic>
#include <cstring>
#include <dlfcn.h>
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, "PIF/Native", __VA_ARGS__)
namespace pif {
// The platform exposes one process-wide property callback. Its immutable owner is
// installed once before the hook is published and lives with the target process.
static std::atomic<PropertyHook *> installed{nullptr};
// Real __system_property_get, kept for the defensive path where a caller enters the
// replacement after the hook state is gone; it mirrors bionic's not-found behavior.
static std::atomic<PropertyGet> realGet{nullptr};
void PropertyHook::modify(void *opaque,const char *name,const char *value,uint32_t serial) {
    auto *context=static_cast<Context *>(opaque); auto *owner=context->owner;
    const char *replacement=value;
    if(name && value) {
        auto exact=owner->properties.find(name);
        if(exact!=owner->properties.end()) replacement=exact->second.c_str();
        else for(const auto &[key,candidate]:owner->properties) {
            if(key.starts_with("*") && std::string_view(name).ends_with(std::string_view(key).substr(1))) {replacement=candidate.c_str();break;}
        }
        if(owner->logLevel>99 || replacement!=value) LOGD("[%s]: %s -> %s",name,value,replacement);
    }
    context->callback(context->cookie,name,replacement,serial);
}
void PropertyHook::copyValue(void *cookie,const char *,const char *value,uint32_t) {
    auto *destination=static_cast<char *>(cookie);
    if(value) strlcpy(destination,value,PROP_VALUE_MAX);
    else destination[0]='\0';
}
// Replacement for every caller's imported __system_property_read_callback.
void PropertyHook::read(const prop_info *info,PropertyCallback callback,void *cookie) {
    BYTEHOOK_POP_STACK();
    auto *owner=installed.load(std::memory_order_acquire);
    if(!owner || !owner->original) return;
    if(!info || !callback) return owner->original(info,callback,cookie);
    Context context{owner,callback,cookie};
    owner->original(info,modify,&context);
}
// Replacement for every caller's imported __system_property_get, mirroring bionic: the
// caller's buffer stays untouched when the property does not exist and -1 is returned.
int PropertyHook::get(const char *name,char *value) {
    BYTEHOOK_POP_STACK();
    auto *owner=installed.load(std::memory_order_acquire);
    if(!owner || !owner->original || !owner->originalFind || !name || !value) {
        const auto fallback=realGet.load(std::memory_order_acquire);
        if(!fallback) { if(value) value[0]='\0'; return -1; }
        return fallback(name,value);
    }
    const prop_info *info=owner->originalFind(name);
    if(!info) return -1;
    Context context{owner,copyValue,value};
    owner->original(info,modify,&context);
    return static_cast<int>(strnlen(value,PROP_VALUE_MAX));
}
bool PropertyHook::install(const Settings &settings) {
    properties=settings.properties;logLevel=settings.verboseLogs;
    // Initialization is idempotent; a ByteHook instance another component already
    // initialized in this process keeps serving hooks, so its status is authoritative.
    const int status=bytehook_init(BYTEHOOK_MODE_AUTOMATIC,false);
    if(status!=BYTEHOOK_STATUS_CODE_OK) { LOGD("ByteHook initialization failed: %d",status);return false; }
    auto *readSymbol=dlsym(RTLD_DEFAULT,"__system_property_read_callback");
    auto *findSymbol=dlsym(RTLD_DEFAULT,"__system_property_find");
    auto *getSymbol=dlsym(RTLD_DEFAULT,"__system_property_get");
    if(!readSymbol || !findSymbol || !getSymbol) { LOGD("Property symbol unavailable");return false; }
    original=reinterpret_cast<PropertyRead>(readSymbol);
    originalFind=reinterpret_cast<PropertyFind>(findSymbol);
    realGet.store(reinterpret_cast<PropertyGet>(getSymbol),std::memory_order_release);
    installed.store(this,std::memory_order_release);
    // AUTOMATIC mode also hooks libraries the process loads after this point, which is
    // when GMS maps its own native code.
    auto *readStub=bytehook_hook_all("libc.so","__system_property_read_callback",reinterpret_cast<void *>(read),nullptr,nullptr);
    auto *getStub=bytehook_hook_all("libc.so","__system_property_get",reinterpret_cast<void *>(get),nullptr,nullptr);
    if(!readStub || !getStub) {
        if(readStub) bytehook_unhook(readStub);
        if(getStub) bytehook_unhook(getStub);
        installed.store(nullptr,std::memory_order_release);
        LOGD("Property hook failed");
        return false;
    }
    LOGD("Property hook initialized");
    return true;
}
}
