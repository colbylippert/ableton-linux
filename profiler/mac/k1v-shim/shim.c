// A VST3 entry shim for Nils' K1v on macOS. Live 12 loads a macOS VST3 bundle only when it exports bundleEntry and
// bundleExit; K1v 1.2.6 (2022, the current Mac VST3) exports only GetPluginFactory, so Live reports "bundle does not
// export the required 'bundleEntry' function" and skips it. This bundle exports all three: bundleEntry opens the
// original binary, kept unchanged with its developer signature in Contents/Resources, and GetPluginFactory returns the
// original's factory, so Live sees the same plugin with the same class IDs (the bench's VSTs Set references them).
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdbool.h>

#define EXPORT __attribute__((visibility("default")))

static void *original;

EXPORT bool bundleEntry(CFBundleRef bundle)
{
    char path[4096];
    CFURLRef url;
    bool ok;

    if (original)
        return true;
    url = CFBundleCopyResourceURL(bundle, CFSTR("NilsK1vVST3"), NULL, NULL);
    if (!url)
        return false;
    ok = CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof path);
    CFRelease(url);
    if (ok)
        original = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    return original != NULL;
}

EXPORT bool bundleExit(void)
{
    return true;    // the original stays loaded until the host exits, as a plugin without bundleExit would
}

EXPORT void *GetPluginFactory(void)
{
    void *(*factory)(void);

    if (!original)
        return NULL;
    factory = (void *(*)(void))dlsym(original, "GetPluginFactory");
    return factory ? factory() : NULL;
}
