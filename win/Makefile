BINARY_FILE = ssd_write_test.exe
SOURCE_FILE = ssd_write_test.rs

BLUE = \033[0;34m
RED = \033[0;31m
NC = \033[0m

.PHONY: all clean

all: check-rust
	@echo "$(BLUE)Building with Cargo...$(NC)"
	cargo build --release
	@echo "Build successful"

check-rust:
	@if ! command -v rustc > /dev/null 2>&1; then \
		echo "$(RED)Error: Rust compiler (rustc) not found.$(NC)"; \
		echo "Please install Rust from https://www.rust-lang.org/tools/install"; \
		exit 1; \
	fi

clean:
	@echo "$(BLUE)Cleaning with Cargo...$(NC)"
	cargo clean
	rm -f result.csv
	rm -f *.tmp
