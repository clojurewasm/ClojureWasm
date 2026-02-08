# WASI Preview 1 Support

ClojureWasm implements WASI Preview 1 (`wasi_snapshot_preview1`) for running
WASI-compiled modules. Load with `(wasm/load-wasi "module.wasm")`.

## Coverage: 19/45 functions (42%)

### Implemented Functions

| Function | Description | Status |
|----------|-------------|--------|
| `args_get` | Read command-line arguments | Done |
| `args_sizes_get` | Get argument sizes | Done |
| `environ_get` | Read environment variables | Done |
| `environ_sizes_get` | Get environment variable sizes | Done |
| `clock_time_get` | Get wall/monotonic clock | Done |
| `fd_close` | Close file descriptor | Done |
| `fd_fdstat_get` | Get fd status/type | Done |
| `fd_filestat_get` | Get file metadata by fd | Done |
| `fd_prestat_get` | Get preopened directory info | Done |
| `fd_prestat_dir_name` | Get preopened directory name | Done |
| `fd_read` | Read from fd | Done |
| `fd_readdir` | Read directory entries | Stub (empty) |
| `fd_seek` | Seek within fd | Done |
| `fd_tell` | Get current fd offset | Done |
| `fd_write` | Write to fd (stdout/stderr/file) | Done |
| `path_filestat_get` | Get file metadata by path | Stub |
| `path_open` | Open file by path | Stub (NOENT) |
| `proc_exit` | Exit process | Done |
| `random_get` | Fill buffer with random bytes | Done |

### Not Implemented (26 functions)

#### High Priority (common in real modules)

| Function | Description |
|----------|-------------|
| `clock_res_get` | Get clock resolution |
| `fd_datasync` | Synchronize fd data |
| `fd_sync` | Synchronize fd data and metadata |
| `path_create_directory` | Create directory |
| `path_remove_directory` | Remove directory |
| `path_unlink_file` | Delete file |
| `path_rename` | Rename file or directory |
| `sched_yield` | Yield execution |

#### Medium Priority

| Function | Description |
|----------|-------------|
| `fd_advise` | Advise on fd access pattern |
| `fd_allocate` | Preallocate fd space |
| `fd_fdstat_set_flags` | Set fd flags |
| `fd_filestat_set_size` | Set file size |
| `fd_filestat_set_times` | Set file timestamps |
| `fd_pread` | Positional read |
| `fd_pwrite` | Positional write |
| `fd_renumber` | Renumber fd (dup2) |
| `path_filestat_set_times` | Set file timestamps by path |
| `path_readlink` | Read symbolic link |
| `path_symlink` | Create symbolic link |

#### Low Priority (sockets, rarely used)

| Function | Description |
|----------|-------------|
| `path_link` | Create hard link |
| `poll_oneoff` | Poll for events |
| `proc_raise` | Raise signal |
| `sock_accept` | Accept socket connection |
| `sock_recv` | Receive from socket |
| `sock_send` | Send to socket |
| `sock_shutdown` | Shutdown socket |

## Usage

```clojure
;; Load WASI module
(def mod (wasm/load-wasi "module.wasm"))

;; Call exported functions
(def main (wasm/fn mod "_start"))
(main)
```

## Architecture

WASI functions are registered as host functions in the Wasm store. Each function
pops arguments from the Wasm operand stack, performs the operation using Zig's
`std.posix` APIs, and pushes the errno result.

Source: `src/wasm/runtime/wasi.zig`
