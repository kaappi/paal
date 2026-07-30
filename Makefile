KAAPPI      ?= kaappi
LIB          = lib
KAAPPI_TEST ?= ../kaappi-test/lib

LIBS = --lib-path $(LIB) --lib-path $(KAAPPI_TEST)

.PHONY: all test coverage clean

all: test

test:
	$(KAAPPI) --coverage-xml coverage.xml $(LIBS) tests/test-paal.scm

coverage:
	$(KAAPPI) --coverage $(LIBS) tests/test-paal.scm

# Run pkaappi via the bootstrap interpreter.
# Usage: make run ARGS="run file.scm"  or  make run ARGS="eval '(+ 1 2)'"
run:
	$(KAAPPI) $(LIBS) src/main.scm $(ARGS)

clean:
	rm -f coverage.xml pkaappi
