# nproc.asm

A reimplementation of GNU `nproc` in x86-64 Linux assembly (NASM).

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
$ OMP_NUM_THREADS=2 ./nproc
2
$ OMP_THREAD_LIMIT=1 ./nproc
1
```

### Syscalls used

| #   | Name                | Purpose                               |
| --- | ------------------- | ------------------------------------- |
| 0   | `read`              | Read `/sys/devices/system/cpu/online` |
| 1   | `write`             | Output result to stdout               |
| 2   | `open`              | Open sysfs CPU file                   |
| 3   | `close`             | Close fd                              |
| 60  | `exit`              | Clean exit (status 0)                 |
| 204 | `sched_getaffinity` | Get CPU affinity mask                 |

## License

Public domain.
