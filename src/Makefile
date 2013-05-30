TARGETS = simtex

OPTIONS = #-g -DDEBUG

all: $(TARGETS)

%: %.l
	flex $<
	g++ $(OPTIONS) lex.yy.c -lfl -o $@
	
clean:
	rm -rf $(TARGETS) lex.yy.c
	
