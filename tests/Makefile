TARGETS = test.out index.html base.html style.css
DEBRIS = debug.out

SIMTEX = ../src/simtex
.PHONY: simtex

all: $(TARGETS)

test.out: test.txt simtex
	$(SIMTEX) < $< > test.out 2>&1

%.html: %.htm simtex
	$(SIMTEX) < $< > $@

style.css: layout.css
	$(SIMTEX) < $^ > $@

debug.out: simtex
	valgrind --leak-check=full --show-reachable=yes -v $(SIMTEX) < test.txt > debug.out 2>&1
	
simtex:
	make -C ../src
		
clean: 
	rm -rf $(TARGETS) $(DEBRIS)
	
