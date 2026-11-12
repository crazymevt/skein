# A Linux to run Skein's tests in, as CI's Linux job has it: SBCL 2.4+ (Debian's) with
# Quicklisp, Zig 0.17.1 and the build tools. tools/linux/run.sh builds it as skein-linux
# and runs a command in it on a copy of the checkout. On an Apple Silicon Mac it is arm64
# Linux (CI's is x86_64): the same system, another processor.
FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends sbcl build-essential make git curl \
      ca-certificates xz-utils bzip2 rsync python3 \
 && rm -rf /var/lib/apt/lists/*

# Zig 0.17.1 for this machine, checked against https://ziglang.org/download/index.json
RUN case "$(uname -m)" in \
      aarch64) arch=aarch64 sum=a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795 ;; \
      x86_64) arch=x86_64 sum=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a ;; \
      *) echo "no Zig for $(uname -m)"; exit 1 ;; \
    esac \
 && curl -fsSL -o /tmp/zig.tar.xz \
      "https://ziglang.org/download/0.17.1/zig-$arch-linux-0.17.1.tar.xz" \
 && echo "$sum  /tmp/zig.tar.xz" | sha256sum -c - \
 && mkdir -p /opt/zig && tar xJf /tmp/zig.tar.xz -C /opt/zig --strip-components 1 \
 && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:${PATH}"

# Quicklisp, as CI installs it
RUN curl -fsSL -o /tmp/quicklisp.lisp https://beta.quicklisp.org/quicklisp.lisp \
 && sbcl --noinform --no-userinit --non-interactive \
      --load /tmp/quicklisp.lisp --eval "(quicklisp-quickstart:install)" \
 && rm /tmp/quicklisp.lisp

WORKDIR /work
