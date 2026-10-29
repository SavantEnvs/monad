// libFuzzer entry for the staking-contract simulator in
// category/execution/monad/staking/fuzzer/staking_contract_fuzzer.cpp, whose own main() takes a
// --seed/--depth/--monad-rev command line. Here those three come from the fuzzer's bytes.
#include <category/execution/monad/staking/fuzzer/staking_contract_machine.hpp>
#include <category/execution/monad/staking/test/input_generation.hpp>
#include <category/vm/evm/monad/revision.h>
#include <category/vm/evm/switch_traits.hpp>
#include <category/vm/evm/traits.hpp>

#include <cstddef>
#include <cstdint>
#include <cstring>

using namespace monad;
using namespace monad::staking;
using namespace monad::staking::test;
using namespace monad::staking::test::fuzzing;

template <Traits traits>
using Transition = StakingContractMachine<traits>::Transition;

template <Traits traits>
static Transition<traits> gen_transition(StakingContractMachine<traits> &machine)
{
    auto const p = machine.gen() % 100;
    if (p < 30) {
        if (p < 20) {
            return Transition<traits>::syscall_reward;
        }
        return Transition<traits>::precompile_external_reward;
    }
    return machine.gen_transition();
}

template <Traits traits>
static int run_simulation(seed_t seed, uint64_t depth)
{
    StakingContractMachine<traits> machine{seed};
    for (uint64_t i = 0; i < depth; ++i) {
        (void)machine.transition(gen_transition(machine));
    }
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(uint8_t const *data, size_t size)
{
    if (size < sizeof(uint64_t) + 2) {
        return -1;
    }
    seed_t seed = 0;
    std::memcpy(&seed, data, sizeof(uint64_t));
    auto const rev = static_cast<monad_revision>(
        data[8] % (static_cast<int>(MONAD_NEXT) + 1));
    uint64_t const depth = 1 + data[9] % 64;
    SWITCH_MONAD_TRAITS(run_simulation, seed, depth);
    return 0;
}
