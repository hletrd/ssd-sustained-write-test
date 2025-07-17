# SSD Sustained Write Speed Test

Sustained write speed test for an SSD, written in Swift.

## Building

```bash
make
```

## Usage

```bash
./ssd_write_test [options]
```

### Options

- `-d, --directory <path>` - Target directory (default: current directory)
- `-r, --ratio <0.0-1.0>` - Size ratio of available space to use (default: 0.9)
- `-c, --chunk-size <bytes>` - Chunk size in bytes (default: 10485760 = 10MB)
- `-i, --interval <bytes>` - Record interval in bytes (default: 1073741824 = 1GB)
- `-o, --output <file>` - Output CSV file (default: result.csv)
- `-v, --verify` - Enable data verification (default: disabled)
- `-h, --help` - Show help message

### Examples

Test with default settings (write-only test):
```bash
./ssd_write_test
```

Test with read verification:
```bash
./ssd_write_test -v
```

Test with 50% of available space and 50MB recording intervals:
```bash
./ssd_write_test -r 0.5 -i 52428800
```

Test on external drive with verification:
```bash
./ssd_write_test -d /Volumes/Untitled -v
```

## Requirements

- macOS
- Swift compiler (install via `xcode-select --install`)
