TARGETS = src

.PHONY: src tests

all: $(TARGETS)

clean: clean-src clean-tests

src:
	$(MAKE) -C src
tests:
	$(MAKE) -C tests

clean-src:
	$(MAKE) -C src clean
clean-tests:
	$(MAKE) -C tests clean
	

