BINARY_FILE = ssd_write_test
SOURCE_FILE = ssd_write_test.swift
SWIFT_FLAGS = -O

BLUE = \033[0;34m
RED = \033[0;31m
NC = \033[0m

.PHONY: all clean

all: $(BINARY_FILE)

check-swift:
	@if ! command -v swiftc > /dev/null 2>&1; then \
		echo "$(RED)Error: Swift compiler (swiftc) not found.$(NC)"; \
		echo "Please install Swift from https://swift.org/download/"; \
		echo "Or install Xcode Command Line Tools: xcode-select --install"; \
		exit 1; \
	fi

$(BINARY_FILE): $(SOURCE_FILE) | check-swift
	@echo "$(BLUE)Compiling $(BINARY_FILE)...$(NC)"
	swiftc $(SWIFT_FLAGS) -o $(BINARY_FILE) $(SOURCE_FILE)
	@echo "Compilation successful: $(BINARY_FILE)"

clean:
	rm -f $(BINARY_FILE)
	rm -f result.csv
	rm -f *.tmp
