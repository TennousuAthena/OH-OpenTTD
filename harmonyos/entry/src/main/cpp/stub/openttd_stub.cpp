// openttd_stub.cpp — placeholder for the OpenTTD game core shared library
// (libopenttd.so). Builds as an independent shared object so the HAP carries
// the two-library split (host bridge + game core) from day one.
//
// The real OpenTTD core replaces this stub in a later wave; the exported
// entry point and its version contract are the stable interface the lifecycle
// bridge dlopen()s.

extern "C" int openttd_native_init(void)
{
    // Version sentinel returned to libentry.so on surface creation.
    return 42;
}
