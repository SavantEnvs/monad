# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form, PREFERRED) — builds ON TOP of the org C/C++ base
# image (ghcr.io/savantenvs/base). The base already provides debian + clang/llvm +
# libFuzzer/afl++ + the identities + the build-contract ENV, so this only adds the
# per-commit build (built on top of the prebuilt base, rather than building the toolchain in-image).
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t mytag .

# The org base, pinned to a fixed DATE-tagged base (YYYYMMDD; shared by all integrations
# minted against it). Use the current dated tag; pin by digest in production: ...base@sha256:<digest>.
FROM ghcr.io/savantenvs/base:20261023

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV — an
# empty value breaks clang ("must be a non-negative decimal integer") both here and for
# any in-image rebuild. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# To change it for a build (e.g. ASan-only, or add MSan): --build-arg SANITIZER_FLAGS="...".
# Declare it WITHOUT a default (no '='): an undefaulted ARG lets the base ENV flow through to
# build.sh when not passed, and an explicit --build-arg overrides it. (An empty default — `=` —
# would instead shadow the base ENV and silently wipe the sanitizers.)
ARG SANITIZER_FLAGS
# Coverage (optional, off by default): instrument the TEST build to measure how much of the project
# the suite exercises — --build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping".
# Empty by default (no effect on the normal oracle build); build.sh appends it to the test build only.
ARG COVERAGE_FLAGS=
# Build parallelism (optional). build.sh falls back to nproc when unset: --build-arg MAYHEM_JOBS=8
ARG MAYHEM_JOBS=

# monad needs clang 19 + libstdc++ 15 (C++26) plus boost 1.83, TBB, liburing, libarchive, brotli,
# zstd, libcap, CLI11, gtest, gmp and ninja; the compiler fuzzer's reference VM is OCaml (opam). The libstdc++-15 headers come from a PINNED Debian
# forky snapshot at low apt priority: only libstdc++-15-dev / libgcc-15-dev are taken from it
# (a newer snapshot would also upgrade libc6/libstdc++6). Dockerfile steps have network; build.sh
# then runs offline against what is installed here.
USER root
RUN printf 'Types: deb\nURIs: http://snapshot.debian.org/archive/debian/20251101T000000Z\nSuites: forky\nComponents: main\nCheck-Valid-Until: no\nSigned-By: /usr/share/keyrings/debian-archive-keyring.pgp\n' > /etc/apt/sources.list.d/forky.sources \
 && printf 'Package: *\nPin: release n=forky\nPin-Priority: 100\n' > /etc/apt/preferences.d/forky \
 && printf 'Acquire::Retries "10";\n' > /etc/apt/apt.conf.d/80retries \
 && apt-get update && apt-get install -yq --no-install-recommends \
      libarchive-dev libbrotli-dev libcap-dev libcli11-dev libgmp-dev libtbb-dev liburing-dev libzstd-dev \
      libboost1.83-dev libboost-context1.83-dev libboost-json1.83-dev libboost-stacktrace1.83-dev libboost-test1.83-dev \
      libgtest-dev libgmock-dev ninja-build pkg-config opam rsync libffi-dev \
 && for i in 1 2 3 4 5 6; do \
      apt-get install -yq --no-install-recommends -t forky libstdc++-15-dev libgcc-15-dev && break; \
      [ "$i" -lt 6 ] || exit 1; sleep 20; done \
 && rm -rf /var/lib/apt/lists/*
# If mayhem/build.sh needs EXTRA apt packages, install them as root before the build
# (re-pin to SOURCE_DATE_EPOCH first for reproducibility — repro-sources-list.sh ships
# in the base):
#   USER root
#   RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
#       apt-get update && apt-get install -yq --no-install-recommends <pkgs> \
#    && rm -rf /var/lib/apt/lists/*
#   USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git
# history) is copied to /mayhem as `mayhem`; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# upstream vendors its dependencies as git submodules (pinned by gitlink sha), which a plain checkout
# leaves empty. Fetch the ones the build needs here (build.sh is offline); the tests-only submodules
# (ethereum-tests, zkevm-standards) are skipped, and monad-execution-specs is fetched below.
RUN retry() { for i in 1 2 3 4 5 6; do "$@" && return 0; sleep 20; done; return 1; } \
 && retry git submodule update --init --recursive --depth 1 \
      $(git submodule status | awk '{print $2}' | grep -v -e ethereum-tests -e monad-execution-specs -e zkevm-standards)

# The compiler fuzzer (monad-compiler-fuzzer) compares the JIT against upstream's OCaml reference VM,
# which cmake builds with dune from the monad-spec opam switch. Create the switch here (network): same
# steps as scripts/ubuntu-build/install-ocaml.sh, plus --disable-sandboxing because bwrap cannot run
# inside `docker build`. Of the spec's own submodules only evmc is needed (tests is 2.9 GB).
# The steps that hit the network are retried: a single dropped download must not fail the image build.
RUN retry() { for i in 1 2 3 4 5 6; do "$@" && return 0; sleep 20; done; return 1; } \
 && retry git submodule update --init --depth 1 third_party/monad-execution-specs \
 && retry git -C third_party/monad-execution-specs submodule update --init --depth 1 third_party/evmc \
 && { opam init --bare -n -y --disable-sandboxing || retry opam update -y; } \
 && opam switch create monad-spec --empty --no-switch -y \
 && retry opam install --switch=monad-spec --deps-only -y third_party/monad-execution-specs

# Anything a Dockerfile step materializes into the tree (downloaded fixtures, generated headers,
# vendored deps) MUST be committed or (re)created by build.sh: rlenv's patch grader runs
# `git clean -ffdX` before every graded build, so a gitignored, untracked file is gone by then and
# every honest patch scores zero (SPEC §6.2 item 16; verify-repo.sh checks it).
#
# OPTIONAL compile-cache pre-fill (SPEC §6.2 item 18). Bases minted with /opt/mayhem/ccache/prefill
# run the build under rlenv's pinned ccache, so the patch grader's first (otherwise cold) rebuild is
# warm — this is what keeps large C/C++ targets inside the build time limit. Older bases fall back to
# the plain build; a missing or stale pre-fill only costs a cold cache. Never enable ccache in
# build.sh or via ENV/PATH, and keep the compiler resolving by name (CC=clang) or nothing is cached.
RUN if [ -x /opt/mayhem/ccache/prefill ]; then /opt/mayhem/ccache/prefill bash mayhem/build.sh; \
    else bash mayhem/build.sh; fi

# Run the project's functional tests at build time IF the repo ships them (mayhem/test.sh is
# optional — omit it only when the repo has no tests meaningful for RL). A failing suite fails the
# image build, so the commit image is guaranteed to build AND pass its own tests.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
