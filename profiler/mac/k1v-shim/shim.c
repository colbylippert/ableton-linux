// A VST3 entry shim for Nils' K1v on macOS. Live 12 loads a macOS VST3 bundle only when it exports bundleEntry and
// bundleExit; K1v 1.2.6 (2022, the current Mac VST3) exports only GetPluginFactory, so Live reports "bundle does not
// export the required 'bundleEntry' function" and skips it. This bundle exports all three: bundleEntry opens the
// original binary inside the original bundle, kept whole and unchanged in Contents/Resources/K1vOriginal.bundle (so its
// developer signature, which covers the bundle's Info.plist, stays valid), and GetPluginFactory returns the original's
// factory, so Live sees the same plugin with the same class IDs (the bench's VSTs Set references them). A failure to
// open the original is appended to /tmp/k1v-shim.log.
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#define EXPORT __attribute__((visibility("default")))

static void *original;

static void note(const char *what, const char *detail)
{
    FILE *f = fopen("/tmp/k1v-shim.log", "a");
    if (f) {
        fprintf(f, "k1v-shim: %s: %s\n", what, detail ? detail : "");
        fclose(f);
    }
}

EXPORT bool bundleEntry(CFBundleRef bundle)
{
    char path[4096];
    CFURLRef url;
    bool ok;

    if (original)
        return true;
    url = CFBundleCopyResourceURL(bundle, CFSTR("K1vOriginal"), CFSTR("bundle"), NULL);
    if (!url) {
        note("no Resources/K1vOriginal.bundle", NULL);
        return false;
    }
    ok = CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof path);
    CFRelease(url);
    if (!ok || strlen(path) + 40 > sizeof path) {
        note("bad path", NULL);
        return false;
    }
    strcat(path, "/Contents/MacOS/NilsK1vVST3");
    original = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!original)
        note("dlopen failed", dlerror());
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
