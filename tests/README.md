# AstroNvim e2e test harness

The harness runs against two roots:

- `source_root` is the AstroNvim checkout under test.
- `harness_root` is this repository and contains the runner, fixtures, e2e specs, and goldens.

`tests/config.lua` reads `ASTRONVIM_SOURCE_ROOT` and `ASTRONVIM_E2E_ROOT`. The Makefile sets both values for local and CI runs.

The generated `.tests/` environment is created under the source checkout. It resolves the latest stable lazy.nvim and AstroNvim plugin graph. The committed `tests/lazy-lock.json` from the AstroNvim source repository is not execution input.

The full suite runs source unit specs together with the external e2e specs. The semantic suite uses the same paths and sets `ASTRONVIM_TEST_SEMANTIC=1` to skip visual goldens. The harness unit targets cover child lifecycle and generated-environment safety.

Tests should verify AstroNvim-owned integration boundaries, lifecycle outcomes, public editor state, filesystem effects, notifications, protocol traffic, and runtime compatibility. They should not duplicate upstream plugin implementation tests or depend on exact private option layouts.
