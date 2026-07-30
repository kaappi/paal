KAAPPI      ?= kaappi
KAAPPI_SRC  ?= ../kaappi
LIB          = lib
KAAPPI_TEST ?= ../kaappi-test/lib

LIBS = --lib-path $(LIB) --lib-path $(KAAPPI_TEST)

.PHONY: all test coverage run binary check-binary clean

all: test

test:
	$(KAAPPI) --coverage-xml coverage.xml $(LIBS) tests/test-paal.scm

coverage:
	$(KAAPPI) --coverage $(LIBS) tests/test-paal.scm

# Run pkaappi via the bootstrap interpreter (no build step needed).
# Usage: make run ARGS="run file.scm"  or  make run ARGS="eval '(+ 1 2)'"
run:
	$(KAAPPI) $(LIBS) src/main.scm $(ARGS)

# Build a standalone pkaappi binary (requires kaappi source + zig).
# Override KAAPPI_SRC if the kaappi repo is not at ../kaappi.
#
# Two-step process:
#   1. Build kaappi from source (if not already built).
#   2. Compile main.scm to bytecode using that binary (so format versions match).
#   3. Bundle the bytecode into the final binary.
KAAPPI_BIN = $(KAAPPI_SRC)/zig-out/bin/kaappi

binary: src/main.scm
	# Build plain kaappi first so KAAPPI_BIN is not a previous bundled pkaappi.
	# zig caches aggressively, so this is fast if nothing changed.
	cd $(KAAPPI_SRC) && zig build
	$(KAAPPI_BIN) --compile $(LIBS) src/main.scm -o pkaappi.sbc
	cd $(KAAPPI_SRC) && zig build -Dbundle=$(CURDIR)/pkaappi.sbc
	cp $(KAAPPI_SRC)/zig-out/bin/kaappi pkaappi
	rm -f pkaappi.sbc
	@echo "Built: pkaappi"

# Smoke-test the built binary.
check-binary: pkaappi
	./pkaappi version
	./pkaappi eval '(+ 1 2)'
	./pkaappi eval '(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 5)'

clean:
	rm -f coverage.xml pkaappi
