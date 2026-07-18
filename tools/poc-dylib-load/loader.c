// A stand-in for a process that dlopen()s a foreign native library — exactly
// what the venv Python interpreter does when it imports the MLX/torch
// extensions during `vllm serve`.
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <dylib-path>\n", argv[0]);
        return 2;
    }
    void *handle = dlopen(argv[1], RTLD_NOW);
    if (!handle) {
        fprintf(stderr, "DLOPEN_FAIL: %s\n", dlerror());
        return 1;
    }
    int (*answer)(void) = (int (*)(void))dlsym(handle, "poc_answer");
    if (!answer) {
        fprintf(stderr, "DLSYM_FAIL: %s\n", dlerror());
        return 1;
    }
    printf("POC_OK %d\n", answer());
    return 0;
}
