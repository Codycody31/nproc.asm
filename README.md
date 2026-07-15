# nproc.asm

A GNU-compatible `nproc` reimplementation in Linux x86-64 assembly (NASM).

## Usage

```sh
$ ./nproc
4
$ ./nproc --all
8
$ ./nproc --ignore=2
2
$ ./nproc --ignore 2
2
$ ./nproc --help
Usage: nproc [OPTION]...
$ ./nproc --version
nproc.asm (GNU-compatible nproc) 0.1
$ OMP_NUM_THREADS=2 ./nproc
2
$ OMP_THREAD_LIMIT=1 ./nproc
1
```

## Compatibility

The current implementation targets GNU coreutils `nproc` 9.10 behavior on
Linux/x86-64.

- Supports `--all`, `--ignore=N`, `--ignore N`, `--help`, and `--version`
- Honors `OMP_NUM_THREADS` and `OMP_THREAD_LIMIT` like GNU `nproc`
- Uses `sched_getaffinity`, `/sys/devices/system/cpu/{online,possible}`, and
  `/proc/stat` fallbacks
- Applies Linux cgroup v2 CPU quota clamping in normal mode
- Keeps output/help text in English only; it does not implement gettext or
  locale-specific translations

## Build And Test

Enter the Nix development shell, then build and run the compatibility suite:

```sh
nix develop
make
make check
```

With direnv installed, `direnv allow` activates the same shell automatically.

### Syscalls used

| #   | Name                  | Purpose                                 |
| --- | --------------------- | --------------------------------------- |
| 0   | `read`                | Read procfs, sysfs, and cgroup files    |
| 1   | `write`               | Output counts, help, version, and errors |
| 2   | `open`                | Open procfs, sysfs, and cgroup files    |
| 3   | `close`               | Close file descriptors                  |
| 9   | `mmap`                | Allocate a dynamic affinity mask buffer |
| 11  | `munmap`              | Release the affinity mask buffer        |
| 60  | `exit`                | Clean exit                              |
| 145 | `sched_getscheduler`  | Detect scheduler classes that ignore CPU quotas |
| 204 | `sched_getaffinity`   | Get the current process affinity mask   |

## License

Public domain.
