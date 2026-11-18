.PHONY: test test-semantic test-e2e test-prepare test-clear test-update-deps test-fingerprint test-update-goldens test-unit test-harness-unit

SOURCE_ROOT ?= $(abspath ../AstroNvim)
HARNESS_ROOT ?= $(CURDIR)
NVIM ?= nvim
TEST_ENV := ASTRONVIM_SOURCE_ROOT="$(SOURCE_ROOT)" ASTRONVIM_E2E_ROOT="$(HARNESS_ROOT)"
SOURCE_UNIT_SPECS := $(filter-out \
  $(SOURCE_ROOT)/tests/unit/e2e_helpers_spec.lua \
  $(SOURCE_ROOT)/tests/unit/helpers_spec.lua \
  $(SOURCE_ROOT)/tests/unit/test_environment_spec.lua, \
  $(wildcard $(SOURCE_ROOT)/tests/unit/*.lua))
HARNESS_UNIT_SPECS := $(sort $(wildcard $(HARNESS_ROOT)/tests/unit/*_spec.lua))
E2E_SPECS := $(sort $(wildcard $(HARNESS_ROOT)/tests/e2e/*_spec.lua))

TEST_SPECS := $(SOURCE_UNIT_SPECS) $(HARNESS_UNIT_SPECS) $(E2E_SPECS)

# The source checkout supplies AstroNvim and its unit specs. The harness checkout
# supplies the runner, child fixtures, e2e specs, goldens, and generated state.

test test-semantic test-e2e test-unit test-harness-unit: test-prepare

test:
	@cd "$(SOURCE_ROOT)" && $(TEST_ENV) "$(NVIM)" -l "$(HARNESS_ROOT)/tests/minit.lua" --minitest $(TEST_SPECS)

test-semantic:
	@cd "$(SOURCE_ROOT)" && ASTRONVIM_TEST_SEMANTIC=1 $(TEST_ENV) "$(NVIM)" -l "$(HARNESS_ROOT)/tests/minit.lua" --minitest $(TEST_SPECS)

test-e2e:
	@cd "$(SOURCE_ROOT)" && $(TEST_ENV) "$(NVIM)" -l "$(HARNESS_ROOT)/tests/minit.lua" --minitest $(E2E_SPECS)

test-unit:
	@cd "$(SOURCE_ROOT)" && $(TEST_ENV) "$(NVIM)" -l "$(HARNESS_ROOT)/tests/minit.lua" --minitest $(SOURCE_UNIT_SPECS)

test-harness-unit:
	@cd "$(SOURCE_ROOT)" && $(TEST_ENV) "$(NVIM)" -l "$(HARNESS_ROOT)/tests/minit.lua" --minitest $(HARNESS_UNIT_SPECS)

test-prepare:
	@cd "$(SOURCE_ROOT)" && $(TEST_ENV) "$(NVIM)" -l "$(HARNESS_ROOT)/tests/bootstrap.lua"

test-clear:
	@cd "$(SOURCE_ROOT)" && $(TEST_ENV) "$(NVIM)" -l "$(HARNESS_ROOT)/tests/clear_test_environment.lua"

test-update-deps:
	@$(MAKE) test-clear SOURCE_ROOT="$(SOURCE_ROOT)" HARNESS_ROOT="$(HARNESS_ROOT)" NVIM="$(NVIM)"
	@$(MAKE) test-prepare SOURCE_ROOT="$(SOURCE_ROOT)" HARNESS_ROOT="$(HARNESS_ROOT)" NVIM="$(NVIM)"

test-fingerprint:
	@cd "$(SOURCE_ROOT)" && $(TEST_ENV) "$(NVIM)" -l "$(HARNESS_ROOT)/tests/print_fingerprint.lua"

test-update-goldens:
	@ASTRONVIM_TEST_UPDATE_GOLDENS=1 $(MAKE) test SOURCE_ROOT="$(SOURCE_ROOT)" HARNESS_ROOT="$(HARNESS_ROOT)" NVIM="$(NVIM)"
