# AstroNvim e2e tests

This repository contains the optional AstroNvim child-Neovim test harness, integration tests, fixtures, and visual goldens. It is separate from the AstroNvim source repository so normal AstroNvim clones do not need the full e2e suite.

The harness always tests an explicit AstroNvim source checkout. It does not use a committed dependency lockfile as execution input. Fresh runs resolve the latest stable plugin graph and record the generated manifest and lockfile as artifacts.

Local prerequisites are `make`, Git, Neovim 0.12 or newer, and the AstroNvim source checkout. The default sibling layout is:

```text
AstroNvim/
AstroNvim-e2e/
```

Run the full current-runtime suite from this repository:

```sh
make test SOURCE_ROOT=../AstroNvim
```

Run semantic coverage without visual goldens:

```sh
make test-semantic SOURCE_ROOT=../AstroNvim
```

Run only the child-Neovim e2e specs:

```sh
make test-e2e SOURCE_ROOT=../AstroNvim
```

The source and harness roots can be overridden independently:

```sh
make test \
  SOURCE_ROOT=/path/to/AstroNvim \
  HARNESS_ROOT=/path/to/AstroNvim-e2e
```

Generated dependency state belongs to the source checkout under `.tests/`. Use `make test-clear` before rebuilding for a different Neovim runtime or after changing the source plugin graph. Use `make test-update-deps` when an intentional fresh dependency resolution is required.

The e2e suite covers AstroNvim-owned integration boundaries, lifecycle behavior, public editor state, filesystem effects, notifications, protocol traffic, and supported runtime compatibility. It does not attempt to re-test upstream plugin implementations.

CI checks out the source repository and this repository at explicit refs. Artifacts include the source commit, e2e commit, Neovim identity, generated plugin manifest, generated lockfile, logs, and per-case results.
