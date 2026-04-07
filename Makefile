LD = ld
NASM = nasm
BIN = nproc
TEST = tests/nproc-compat.sh

all: $(BIN)

$(BIN): $(BIN).o
	$(LD) $(BIN).o -o $(BIN)

$(BIN).o: $(BIN).asm
	$(NASM) -f elf64 -o $(BIN).o $(BIN).asm

check: $(BIN)
	bash $(TEST)

.PHONY: clean
clean:
	rm -f $(BIN) $(BIN).o
