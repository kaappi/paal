KAAPPI  ?= kaappi
LIB     = lib

.PHONY: all test coverage clean

all: test

test:
	$(KAAPPI) --coverage-xml coverage.xml --lib-path $(LIB) tests/test-paal.scm

coverage:
	$(KAAPPI) --coverage --lib-path $(LIB) tests/test-paal.scm

# Run pkaappi via the bootstrap interpreter.
# Usage: make run ARGS="run file.scm"  or  make run ARGS="eval '(+ 1 2)'"
run:
	$(KAAPPI) --lib-path $(LIB) src/main.scm $(ARGS)

clean:
	rm -f coverage.xml pkaappi
