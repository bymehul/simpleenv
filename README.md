# SimpleEnv

`simpleenv` is a zero-dependency, lightning fast environment variable loader for Odin.

## Features

- Parses `.env` variables line by line conforming to standard POSIX rules
- **Fully Drop-in environment loader**: Accurately parses comments (`#`), interpolations, and supports **Multi-line Values** inside quotes (`"`, `'`, and `` ` ``).
- Loads variables directly into `os.set_env()` to automatically interact with existing Odin abstractions.
- Does not allocate aggressively. Memory safe loading mechanism.

## Installation

This project is built using `odpkg`, the unofficial package manager for Odin.

```bash
odpkg add github.com/bymehul/simpleenv simpleenv
```
If you don't have `odpkg`, you can simply clone this repo and include the `simpleenv` folder inside your project directory.

## Usage

Create a `.env` file in the root of your project:

```env
help=12
main="123cs"
```

Then in your Odin code:

```odin
package main

import "core:fmt"
import "core:os"
import "simpleenv" // or your local path

main :: proc() {
    // 1. Load the .env file
    res, ok := simpleenv.config()
    
    // 2. Check if loading was successful
    if !ok {
        fmt.eprintln("Failed to load .env:", res.read_error)
        return
    }
    
    fmt.println("Successfully loaded .env file!")
    
    // 3. Variables are automatically injected into the OS environment!
    // This is useful if you have third-party packages or C bindings that
    // rely on standard environment variables (requires a temporary allocator).
    help_val_os, _ := os.lookup_env("help", context.temp_allocator)
    
    // OR: You can read them directly from the parsed map!
    // This is much faster, easier to type, and doesn't require allocation.
    // Use this for simply reading config flags directly in your Odin code.
    help_val := res.parsed["help"]
    main_val := res.parsed["main"]
    
    fmt.println("Value of 'help' (from map):", help_val)
    fmt.println("Value of 'help' (from OS):", help_val_os)
    fmt.println("Value of 'main':", main_val)
    
    // 4. (Optional) Cleanup the parsed string map:
    simpleenv.delete_map(res.parsed)
}
```

### Config Options

`config()` accepts an optional `Config_Options` struct:

```odin
opts := simpleenv.Config_Options{
    path = ".env.local", // Custom config file path
    override = true,     // Overwrite existing environment variables (default: false)
}
res, ok := simpleenv.config(opts)
```
