#!/usr/bin/env bash
#
# mayhem/build.sh — build monad's libFuzzer harnesses (sanitized, with -standalone reproducers) and a
# normal-flags build of a pure unit-test subset for mayhem/test.sh. Runs offline and is re-runnable.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# cmake takes the compilers from $CC/$CXX on first configure only; passing -DCMAKE_C_COMPILER on every
# run would make a re-run see "clang" != the cached /usr/bin/clang and wipe the cache.

# immer's node layout trips UBSan's object-size check ("constructor call ... insufficient space for
# node_t") on every staking simulation, so that single check is relaxed; everything else stays halting.
FZ="$SANITIZER_FLAGS -fno-sanitize=object-size -fsanitize=fuzzer-no-link $DEBUG_FLAGS -march=haswell"

# 1) The project, sanitized + coverage-instrumented. No Boost/gtest tests here: only the harness targets.
cmake -S . -B build/fuzz -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_FLAGS="$FZ" -DCMAKE_CXX_FLAGS="$FZ" \
  -DCMAKE_ASM_FLAGS="-march=haswell" \
  -DCMAKE_CXX_SCAN_FOR_MODULES=OFF
ninja -C build/fuzz -j"$MAYHEM_JOBS" \
  monad-trie-fuzz-generated_kv-in_memory_trie_fixture_t \
  monad-trie-fuzz-one_hundred_updates-in_memory_trie_fixture_t \
  monad_staking_contract_fuzzer

# 1b) The VM differential fuzzer needs -DMONAD_COMPILER_TESTING=ON, a project-wide compile definition
# that also builds the OCaml reference VM (dune, from the monad-spec opam switch the Dockerfile creates),
# so it gets its own tree. Only the one target is built, not the unit tests that option also enables.
cmake -S . -B build/compiler-fuzz -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_FLAGS="$FZ" -DCMAKE_CXX_FLAGS="$FZ" \
  -DCMAKE_ASM_FLAGS="-march=haswell" \
  -DCMAKE_CXX_SCAN_FOR_MODULES=OFF \
  -DMONAD_COMPILER_TESTING=ON
ninja -C build/compiler-fuzz -j"$MAYHEM_JOBS" monad-compiler-fuzzer

# 2) Harness binaries: libFuzzer + -standalone (run-once) variants.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build/fuzz/standalone_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build/fuzz/lsan_off.o

python3 - <<'PY'
import os, shlex, subprocess

SRC = os.environ["SRC"]
BD = os.path.join(SRC, "build/fuzz")
STAND = os.path.join(BD, "standalone_main.o")
LSAN = os.path.join(BD, "lsan_off.o")


def commands(target, bd=BD):
    out = subprocess.run(["ninja", "-C", bd, "-t", "commands", target],
                         check=True, capture_output=True, text=True).stdout
    return [l.strip() for l in out.splitlines() if l.strip()]


def split(cmd):
    cmd = cmd.strip()
    if cmd.startswith(": &&"):
        cmd = cmd[len(": &&"):]
    if cmd.endswith("&& :"):
        cmd = cmd[:-len("&& :")]
    return shlex.split(cmd)


def drop_dep_flags(t):
    out, i = [], 0
    while i < len(t):
        if t[i] in ("-MT", "-MF"):
            i += 2
        elif t[i] == "-MD":
            i += 1
        elif t[i] == "-Xlinker" and t[i + 1].startswith("--dependency-file="):
            i += 2
        else:
            out.append(t[i]); i += 1
    return out


def run(tokens, cwd=BD):
    subprocess.run(tokens, check=True, cwd=cwd)


def setval(t, flag, val):
    t[t.index(flag) + 1] = val


# In-tree libFuzzer targets: relink the existing objects with lsan_off and the right engine.
for upstream, name in (
    ("monad-trie-fuzz-generated_kv-in_memory_trie_fixture_t", "trie-generated-kv"),
    ("monad-trie-fuzz-one_hundred_updates-in_memory_trie_fixture_t", "trie-one-hundred-updates"),
):
    link = split(commands(upstream)[-1])
    link = drop_dep_flags(link)
    obj = next(x for x in link if x.endswith(".cpp.o"))
    for suffix, replace in (("", None), ("-standalone", STAND)):
        t = list(link)
        if replace:
            t[t.index("-fsanitize=fuzzer")] = replace
        t.insert(t.index(obj), LSAN)
        setval(t, "-o", os.path.join(SRC, name + suffix))
        run(t)

# mayhem/staking_harness.cpp: same translation unit flags as the upstream staking fuzzer.
cmds = commands("monad_staking_contract_fuzzer")
comp = split(next(c for c in cmds if "staking_contract_fuzzer.cpp.o" in c and " -c " in c))
link = split(cmds[-1])
comp = drop_dep_flags(comp)
src_idx = comp.index("-c") + 1
comp[src_idx] = os.path.join(SRC, "mayhem/staking_harness.cpp")
hobj = os.path.join(BD, "staking_harness.o")
setval(comp, "-o", hobj)
run(comp)
link = drop_dep_flags(link)
obj = next(x for x in link if x.endswith("staking_contract_fuzzer.cpp.o"))
for suffix, engine in (("", os.environ["LIB_FUZZING_ENGINE"].split()), ("-standalone", [STAND])):
    t = list(link)
    i = t.index(obj)
    t[i:i + 1] = [hobj, LSAN] + engine
    setval(t, "-o", os.path.join(SRC, "staking-contract" + suffix))
    run(t)

# mayhem/compiler_harness.cpp: includes upstream's fuzzer.cpp (main renamed) and adds the libFuzzer entry;
# same translation unit flags as monad-compiler-fuzzer, in its own build tree.
CBD = os.path.join(SRC, "build/compiler-fuzz")
cmds = commands("monad-compiler-fuzzer", CBD)
comp = split(next(c for c in cmds if "fuzzer.cpp.o" in c and " -c " in c))
link = split(cmds[-1])
comp = drop_dep_flags(comp)
comp[comp.index("-c") + 1] = os.path.join(SRC, "mayhem/compiler_harness.cpp")
hobj = os.path.join(CBD, "compiler_harness.o")
setval(comp, "-o", hobj)
run(comp, CBD)
link = drop_dep_flags(link)
obj = next(x for x in link if x.endswith("fuzzer.cpp.o"))
for suffix, engine in (("", os.environ["LIB_FUZZING_ENGINE"].split()), ("-standalone", [STAND])):
    t = list(link)
    i = t.index(obj)
    t[i:i + 1] = [hobj, LSAN] + engine
    setval(t, "-o", os.path.join(SRC, "compiler-fuzzer" + suffix))
    run(t, CBD)
PY

# 3) Test oracle: a pure (no io_uring, no disk) subset of upstream's gtest binaries, built with the
# project's normal flags and no sanitizers.
cmake -S . -B build/test -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_FLAGS="-march=haswell $COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="-march=haswell $COVERAGE_FLAGS" \
  -DCMAKE_ASM_FLAGS="-march=haswell" \
  -DCMAKE_CXX_SCAN_FOR_MODULES=OFF
ninja -C build/test -j"$MAYHEM_JOBS" \
  compact_encode_test nibbles_view_test big_endian_serialization_test \
  unsigned_20_test encode_branch_test encode_two_pieces_test
