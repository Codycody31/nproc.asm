LD = ld
NASM = nasm
BIN = nproc
all: $(BIN)
$(BIN): $(BIN).o
	$(LD) $(BIN).o -o $(BIN)
$(BIN).o: $(BIN).asm
	$(NASM) -f elf64 -o $(BIN).o $(BIN).asm
.PHONY: clean
clean:
	rm -f $(BIN) $(BIN).o
