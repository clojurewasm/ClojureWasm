# WASI Preview 1 Support

ClojureWasm implements WASI Preview 1 (`wasi_snapshot_preview1`) for running
WASI-compiled modules. Load with `(wasm/load-wasi "module.wasm")`.

## Coverage: 38/45 functions (84%)

### Implemented Functions

| Function                  | Description                      | Status         |
|---------------------------|----------------------------------|----------------|
| `args_get`                | Read command-line arguments      | Done           |
| `args_sizes_get`          | Get argument sizes               | Done           |
| `clock_res_get`           | Get clock resolution             | Done           |
| `clock_time_get`          | Get wall/monotonic clock         | Done           |
| `environ_get`             | Read environment variables       | Done           |
| `environ_sizes_get`       | Get environment variable sizes   | Done           |
| `fd_advise`               | Advise on fd access pattern      | Stub (success) |
| `fd_allocate`             | Preallocate fd space             | Stub (NOSYS)   |
| `fd_close`                | Close file descriptor            | Done           |
| `fd_datasync`             | Synchronize fd data              | Done           |
| `fd_fdstat_get`           | Get fd status/type               | Done           |
| `fd_fdstat_set_flags`     | Set fd flags                     | Done           |
| `fd_filestat_get`         | Get file metadata by fd          | Done           |
| `fd_filestat_set_size`    | Set file size                    | Done           |
| `fd_filestat_set_times`   | Set file timestamps              | Done           |
| `fd_pread`                | Positional read                  | Done           |
| `fd_prestat_get`          | Get preopened directory info     | Done           |
| `fd_prestat_dir_name`     | Get preopened directory name     | Done           |
| `fd_pwrite`               | Positional write                 | Done           |
| `fd_read`                 | Read from fd                     | Done           |
| `fd_readdir`              | Read directory entries           | Stub (empty)   |
| `fd_renumber`             | Renumber fd (dup2)               | Stub (NOSYS)   |
| `fd_seek`                 | Seek within fd                   | Done           |
| `fd_sync`                 | Synchronize fd data and metadata | Done           |
| `fd_tell`                 | Get current fd offset            | Done           |
| `fd_write`                | Write to fd (stdout/stderr/file) | Done           |
| `path_create_directory`   | Create directory                 | Done           |
| `path_filestat_get`       | Get file metadata by path        | Stub           |
| `path_filestat_set_times` | Set file timestamps by path      | Done           |
| `path_open`               | Open file by path                | Stub (NOENT)   |
| `path_readlink`           | Read symbolic link               | Done           |
| `path_remove_directory`   | Remove directory                 | Done           |
| `path_rename`             | Rename file or directory         | Done           |
| `path_symlink`            | Create symbolic link             | Stub (NOSYS)   |
| `path_unlink_file`        | Delete file                      | Done           |
| `proc_exit`               | Exit process                     | Done           |
| `random_get`              | Fill buffer with random bytes    | Done           |
| `sched_yield`             | Yield execution                  | Done           |

### Not Implemented (7 functions)

#### Low Priority (sockets, rarely used)

| Function               | Description              |
|------------------------|--------------------------|
| `fd_fdstat_set_rights` | Set fd rights            |
| `path_link`            | Create hard link         |
| `poll_oneoff`          | Poll for events          |
| `proc_raise`           | Raise signal             |
| `sock_accept`          | Accept socket connection |
| `sock_recv`            | Receive from socket      |
| `sock_send`            | Send to socket           |
| `sock_shutdown`        | Shutdown socket          |

Note: `fd_fdstat_set_rights` is deprecated in WASI Preview 2 and rarely
used in practice. Socket functions (`sock_*`) require WASI sockets
extension which is not part of the core Preview 1 spec.

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
