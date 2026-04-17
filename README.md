# Foldb

A database for folded data written in Zig.

## Features

- Fast and efficient data storage
- Zig-native implementation
- Cross-platform support

## Requirements

- [Zig](https://ziglang.org/) 0.11.0 or later

## Building

```bash
# Build in release mode
zig build

# Build in debug mode
zig build -Doptimize=Debug

# Run the application
zig build run

# Run tests
zig build test
```

## Installation

```bash
zig build install
```

## Project Structure

```
foldb/
├── build.zig          # Build configuration
├── src/
│   ├── lib.zig        # Core library
│   └── main.zig       # Application entry point
├── .gitignore         # Git ignore rules
└── README.md          # This file
```

## License

MIT License
