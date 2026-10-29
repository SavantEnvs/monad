// libFuzzer entry for the VM differential fuzzer in test/vm/fuzzer/fuzzer.cpp (monad-compiler-fuzzer),
// whose own main() takes --seed/--iterations-per-run/--implementation on the command line and needs
// MONAD_COMPILER_FUZZING=1. Here the first ten input bytes supply those and upstream's run loop is called
// unchanged: it generates programs and messages from the seed, runs them through the OCaml reference VM
// and the compiler (or interpreter), and asserts that results and state agree.
#define main monad_compiler_fuzzer_main
#include <test/vm/fuzzer/fuzzer.cpp>
#undef main

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>

extern "C" int LLVMFuzzerInitialize(int *, char ***)
{
    // Same switch as the MONAD_COMPILER_FUZZING environment variable, which is only read at static init.
    monad::vm::utils::is_fuzzing_monad_vm = true;
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(uint8_t const *data, size_t size)
{
    if (size < sizeof(uint64_t) + 2) {
        return -1;
    }
    uint64_t seed = 0;
    std::memcpy(&seed, data, sizeof(uint64_t));
    // arguments::default_seed means "draw a random seed" (parse_args), which would make the run depend
    // on more than the input.
    if (seed == std::numeric_limits<uint64_t>::max()) {
        return -1;
    }
    auto const seed_str = std::to_string(seed);
    auto const iterations = std::to_string(1 + data[8] % 8);
    char const *const implementation =
        (data[9] & 1) != 0 ? "interpreter" : "compiler";
    std::array<char const *, 9> args{
        "monad-compiler-fuzzer",
        "--seed",
        seed_str.c_str(),
        "--runs",
        "1",
        "-i",
        iterations.c_str(),
        "--implementation",
        implementation};
    run_loop(static_cast<int>(args.size()), const_cast<char **>(args.data()));
    return 0;
}
