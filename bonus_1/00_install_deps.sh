#!/usr/bin/env bash
#
# 00_install_deps.sh - install runtime dependencies on Rocky Linux.
#
# Installs the toolchain needed to build and run the assignment:
#   - clang / LLVM (llvm-profdata, llvm-cov, llvm-addr2line)
#   - gcc, make, git, patch, tar, gzip, diffutils, wget/curl
#   - perl + JSON::PP (used by the patched genhtml)
#   - python3 (used by tools/bb_cov_finalize.py)
#
# Run as root or with sudo, e.g.:
#   sudo bash 00_install_deps.sh
#

set -euo pipefail

echo "==> Installing build dependencies (Rocky Linux / dnf)"

dnf -y install epel-release || true

dnf -y install \
    gcc \
    make \
    git \
    patch \
    tar \
    gzip \
    wget \
    curl \
    diffutils \
    clang \
    llvm \
    perl \
    perl-JSON-PP \
    python3

echo "==> Checking toolchain"

command -v clang           >/dev/null && echo "clang:            $(clang --version | head -1)"
command -v llvm-profdata   >/dev/null && echo "llvm-profdata:    $(llvm-profdata --version | head -1)"
command -v llvm-cov        >/dev/null && echo "llvm-cov:         $(llvm-cov --version | head -1)"
command -v llvm-addr2line  >/dev/null && echo "llvm-addr2line:   available"
command -v perl            >/dev/null && echo "perl:             $(perl -e 'print $^V')"
command -v python3         >/dev/null && echo "python3:          $(python3 --version)"

echo "==> Done. Toolchain is ready."