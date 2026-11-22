#!/usr/bin/env bash
# Portable x86-64-v3 profile (any vendor with AVX2/BMI2/FMA). Do not name a vendor
# microarchitecture here: znver3 emits AMD-only SSE4a and crashes on Intel CPUs.
export EMO_MARCH="x86-64-v3"
export EMO_CFLAGS="-march=x86-64-v3 -mtune=generic -O3 -pipe -fno-plt -fexceptions -Wp,-D_FORTIFY_SOURCE=3 -Wformat -Werror=format-security -fstack-clash-protection"
export EMO_CXXFLAGS="${EMO_CFLAGS} -Wp,-D_GLIBCXX_ASSERTIONS"
export EMO_LDFLAGS="-Wl,-O1 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now"
export EMO_RUSTFLAGS="-C target-cpu=x86-64-v3 -C opt-level=3"
export EMO_CMAKE_CUDA_ARCHITECTURES="89"
