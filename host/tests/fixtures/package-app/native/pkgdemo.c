/* The C library that the package-app fixture bundles (M1.11). */
#if defined(_WIN32)
__declspec(dllexport)
#endif
int pkgdemo_answer(void) { return 42; }
