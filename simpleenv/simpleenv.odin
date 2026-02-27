package simpleenv

import "base:runtime"
import "core:os"
import "core:strings"

Map :: distinct map[string]string

Config_Options :: struct {
	path:     string,
	override: bool,
}

DEFAULT_CONFIG_OPTIONS :: Config_Options{
	path = ".env",
	override = false,
}

Result :: struct {
	parsed:      Map,
	loaded:      int,
	read_error:  os.Error,
	set_error:   os.Error,
	alloc_error: runtime.Allocator_Error,
}

success :: proc(result: Result) -> bool {
	return result.read_error == nil && result.set_error == nil && result.alloc_error == nil
}

delete_map :: proc(env: Map) {
	if env == nil {
		return
	}

	allocator := env.allocator
	for key, value in env {
		delete(key, allocator)
		delete(value, allocator)
	}
	delete(env)
}

@(private)
_is_space_byte :: proc(c: byte) -> bool {
	return c == ' ' || c == '\t'
}

@(private)
_is_valid_key :: proc(key: string) -> bool {
	if len(key) == 0 {
		return false
	}

	for i := 0; i < len(key); i += 1 {
		c := key[i]
		switch c {
		case 'A'..='Z', 'a'..='z', '0'..='9', '_', '.', '-':
		case:
			return false
		}
	}

	return true
}

@(private)
_find_separator :: proc(line: string) -> (index: int, separator: byte, found: bool) {
	for i := 0; i < len(line); i += 1 {
		c := line[i]
		switch c {
		case '=':
			return i, '=', true
		case ':':
			if i+1 < len(line) && _is_space_byte(line[i+1]) {
				return i, ':', true
			}
		}
	}

	return -1, 0, false
}

@(private)
_find_closing_quote :: proc(value: string, quote: byte) -> (index: int, found: bool) {
	escaped := false
	for i := 1; i < len(value); i += 1 {
		c := value[i]
		if escaped {
			escaped = false
			continue
		}
		if c == '\\' {
			escaped = true
			continue
		}
		if c == quote {
			return i, true
		}
	}

	return -1, false
}

@(private)
Assignment :: struct {
	key:   string,
	value: string,
	quote: byte,
}

@(private)
_parse_assignment :: proc(src: string) -> (assignment: Assignment, remaining: string, ok: bool) {
	line_start := 0
	for line_start < len(src) {
		line_end := line_start
		for line_end < len(src) && src[line_end] != '\n' && src[line_end] != '\r' {
			line_end += 1
		}
		
		line := strings.trim_space(src[line_start:line_end])
		
		next_start := line_end
		if next_start < len(src) && src[next_start] == '\r' { next_start += 1 }
		if next_start < len(src) && src[next_start] == '\n' { next_start += 1 }

		if len(line) == 0 || line[0] == '#' {
			line_start = next_start
			continue
		}

		if strings.has_prefix(line, "export") {
			prefix_len :: len("export")
			if len(line) > prefix_len && _is_space_byte(line[prefix_len]) {
				line = strings.trim_space(line[prefix_len+1:])
			}
		}

		sep_idx, sep, found := _find_separator(line)
		if !found {
			line_start = next_start
			continue
		}

		key := strings.trim_space(line[:sep_idx])
		if !_is_valid_key(key) {
			line_start = next_start
			continue
		}

		assignment.key = key
		assignment.quote = 0

		// Find the raw un-trimmed value source from the main src
		// This is so we can read past the first newline if quoted
		value_start_in_line := sep_idx + 1
		if sep == ':' {
			for value_start_in_line < len(line) && _is_space_byte(line[value_start_in_line]) {
				value_start_in_line += 1
			}
		}
		
		val_offset := line_start + (len(src[line_start:line_end]) - len(line)) // roughly start of trimmed line
		
		// Find exactly where the value starts in `src`
		v_start := line_start
		// find the separator in src
		for v_start < len(src) && src[v_start] != sep { v_start += 1 }
		v_start += 1
		
		for v_start < len(src) && _is_space_byte(src[v_start]) { v_start += 1 }

		if v_start >= len(src) || src[v_start] == '\n' || src[v_start] == '\r' {
			assignment.value = ""
			remaining = src[next_start:]
			ok = true
			return
		}
		
		first := src[v_start]
		if first == '"' || first == '\'' || first == '`' {
			assignment.quote = first
			
			// Find closing quote starting from v_start + 1 in SRC to support multiline
			end_idx := -1
			escaped := false
			for i := v_start + 1; i < len(src); i += 1 {
				c := src[i]
				if escaped {
					escaped = false
					continue
				}
				if c == '\\' {
					escaped = true
					continue
				}
				if c == first {
					end_idx = i
					break
				}
			}
			
			if end_idx == -1 {
				// unclosed quote
				line_start = next_start
				continue
			}
			
			assignment.value = src[v_start+1 : end_idx]
			
			// remaining is next line after quote ends
			rem_start := end_idx + 1
			for rem_start < len(src) && src[rem_start] != '\n' && src[rem_start] != '\r' {
				rem_start += 1
			}
			if rem_start < len(src) && src[rem_start] == '\r' { rem_start += 1 }
			if rem_start < len(src) && src[rem_start] == '\n' { rem_start += 1 }
			
			remaining = src[rem_start:]
			ok = true
			return
		}

		// unquoted, read till end of line
		value_source := strings.trim_space(src[v_start:line_end])
		if comment_idx := strings.index_byte(value_source, '#'); comment_idx >= 0 {
			value_source = strings.trim_space(value_source[:comment_idx])
		}
		assignment.value = value_source
		remaining = src[next_start:]
		ok = true
		return
	}
	remaining = ""
	ok = false
	return
}

@(private)
_clone_value :: proc(value: string, quote: byte, allocator := context.allocator, loc := #caller_location) -> (cloned: string, err: runtime.Allocator_Error) {
	if quote != '"' {
		return strings.clone(value, allocator, loc)
	}

	buf, alloc_err := make([]byte, len(value), allocator, loc)
	if alloc_err != nil {
		return "", alloc_err
	}

	write_idx := 0
	i := 0
	for i < len(value) {
		if value[i] == '\\' && i+1 < len(value) {
			switch value[i+1] {
			case 'n':
				buf[write_idx] = '\n'
				write_idx += 1
				i += 2
				continue
			case 'r':
				buf[write_idx] = '\r'
				write_idx += 1
				i += 2
				continue
			}
		}

		buf[write_idx] = value[i]
		write_idx += 1
		i += 1
	}

	return string(buf[:write_idx]), nil
}

parse :: proc(src: string, allocator := context.allocator, loc := #caller_location) -> (env: Map, err: runtime.Allocator_Error) {
	remaining := src
	env = make(Map, 16, allocator) // make it correctly
	
	for len(remaining) > 0 {
		assignment, next_remaining, ok := _parse_assignment(remaining)
		if !ok {
			break
		}
		remaining = next_remaining

		key_copy, key_err := strings.clone(assignment.key, allocator, loc)
		if key_err != nil {
			delete_map(env)
			return nil, key_err
		}

		value_copy, value_err := _clone_value(assignment.value, assignment.quote, allocator, loc)
		if value_err != nil {
			delete(key_copy, allocator)
			delete_map(env)
			return nil, value_err
		}

		if previous, exists := env[assignment.key]; exists {
			delete(previous, allocator)
			delete(key_copy, allocator)
			env[assignment.key] = value_copy
			continue
		}

		env[key_copy] = value_copy
	}

	return env, nil
}

load :: proc(path := ".env", allocator := context.allocator, loc := #caller_location) -> (env: Map, read_error: os.Error, alloc_error: runtime.Allocator_Error) {
	data, file_err := os.read_entire_file(path, allocator)
	if file_err != nil {
		read_error = file_err
		return
	}
	defer delete(data, allocator)

	env, alloc_error = parse(string(data), allocator, loc)
	return
}

populate :: proc(env: Map, override := false) -> (loaded: int, set_error: os.Error) {
	for key, value in env {
		_, exists := os.lookup_env(key, context.temp_allocator)
		if exists && !override {
			continue
		}

		err := os.set_env(key, value)
		if err != nil {
			return loaded, err
		}

		loaded += 1
	}

	return loaded, nil
}

config :: proc(options := DEFAULT_CONFIG_OPTIONS, allocator := context.allocator, loc := #caller_location) -> (result: Result, ok: bool) {
	path := options.path
	if path == "" {
		path = DEFAULT_CONFIG_OPTIONS.path
	}

	result.parsed, result.read_error, result.alloc_error = load(path, allocator, loc)
	if result.read_error != nil || result.alloc_error != nil {
		return
	}

	result.loaded, result.set_error = populate(result.parsed, options.override)
	ok = result.read_error == nil && result.set_error == nil && result.alloc_error == nil
	return
}
