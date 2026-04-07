; GNU-compatible `nproc` clone for Linux/x86-64, written in NASM.
; Build with: nasm -f elf64 nproc.asm && ld -o nproc nproc.o

%define SYS_READ                0
%define SYS_WRITE               1
%define SYS_OPEN                2
%define SYS_CLOSE               3
%define SYS_MMAP                9
%define SYS_MUNMAP              11
%define SYS_SCHED_GETSCHEDULER  145
%define SYS_EXIT                60
%define SYS_SCHED_GETAFFINITY   204

%define STDOUT                  1
%define STDERR                  2
%define O_RDONLY                0
%define PROT_READ               1
%define PROT_WRITE              2
%define MAP_PRIVATE             2
%define MAP_ANONYMOUS           32
%define SCHED_FIFO              1
%define SCHED_RR                2
%define SCHED_DEADLINE          6
%define EINVAL                  22
%define ULONG_MAX               -1
%define AFFINITY_BYTES_INIT     128
%define FILEBUF_SIZE            16384
%define PATHBUF_SIZE            4096

section .rodata
    path_cpu_online:        db '/sys/devices/system/cpu/online', 0
    path_cpu_possible:      db '/sys/devices/system/cpu/possible', 0
    path_proc_stat:         db '/proc/stat', 0
    path_proc_mounts:       db '/proc/mounts', 0
    path_proc_self_cgroup:  db '/proc/self/cgroup', 0
    path_cgroup2_default:   db '/sys/fs/cgroup', 0
    path_cgroup2_ctrl:      db '/sys/fs/cgroup/cgroup.controllers', 0
    suffix_cpu_max:         db '/cpu.max', 0

    opt_all:                db '--all', 0
    opt_help:               db '--help', 0
    opt_version:            db '--version', 0
    opt_ignore:             db '--ignore', 0
    opt_ignore_eq:          db '--ignore=', 0
    opt_end:                db '--', 0

    env_omp_threads:        db 'OMP_NUM_THREADS=', 0
    env_omp_limit:          db 'OMP_THREAD_LIMIT=', 0
    str_cgroup2:            db 'cgroup2', 0

    prog_prefix:            db 'nproc: ', 0
    msg_invalid_number:     db 'invalid number: ', 0
    msg_extra_operand:      db 'extra operand ', 0
    msg_unknown_option:     db 'unrecognized option ', 0
    msg_requires_arg:       db "option '--ignore' requires an argument", 10, 0
    msg_try_help:           db "Try 'nproc --help' for more information.", 10, 0
    quote:                  db "'", 0
    quote_nl:               db "'", 10, 0

    help_text:
        db 'Usage: nproc [OPTION]...', 10
        db 'Print the number of processing units available to the current process,', 10
        db 'which may be less than the number of online or installed processors.', 10
        db 'If OMP_NUM_THREADS or OMP_THREAD_LIMIT are set, they provide the', 10
        db 'minimum and maximum result respectively. Linux cgroup v2 CPU quotas', 10
        db 'are also honored unless --all is specified.', 10, 10
        db '  --all            print the number of installed processors', 10
        db '  --ignore=N       exclude N processing units if possible', 10
        db '  --help           display this help and exit', 10
        db '  --version        output version information and exit', 10, 0

    version_text:
        db 'nproc.asm (GNU-compatible nproc) 0.1', 10
        db 'Behavior-compatible with GNU coreutils nproc 9.10 on Linux/x86-64.', 10, 0

section .bss
    envp_ptr:       resq 1
    ignore_count:   resq 1
    flag_all:       resq 1
    first_operand:  resq 1
    value_arg_ptr:  resq 1
    filebuf:        resb FILEBUF_SIZE
    mountbuf:       resb PATHBUF_SIZE
    cgroupbuf:      resb PATHBUF_SIZE
    pathbuf:        resb PATHBUF_SIZE
    numbuf:         resb 22

section .text
    global _start

_start:
    mov     rbp, rsp
    mov     r12, [rbp]
    lea     rax, [rbp + r12*8 + 16]
    mov     [rel envp_ptr], rax

    xor     eax, eax
    mov     [rel ignore_count], rax
    mov     [rel flag_all], rax
    mov     [rel first_operand], rax
    mov     [rel value_arg_ptr], rax

    mov     r13, 1
    xor     r14d, r14d

parse_args:
    cmp     r13, r12
    jge     args_done
    mov     rbx, [rbp + r13*8 + 8]

    test    r14d, r14d
    jnz     record_operand

    mov     rdi, rbx
    lea     rsi, [rel opt_end]
    call    streq
    test    eax, eax
    jnz     set_endopts

    mov     rdi, rbx
    lea     rsi, [rel opt_help]
    call    streq
    test    eax, eax
    jnz     print_help

    mov     rdi, rbx
    lea     rsi, [rel opt_version]
    call    streq
    test    eax, eax
    jnz     print_version

    mov     rdi, rbx
    lea     rsi, [rel opt_all]
    call    streq
    test    eax, eax
    jz      check_ignore_eq
    mov     qword [rel flag_all], 1
    jmp     next_arg

check_ignore_eq:
    mov     rdi, rbx
    lea     rsi, [rel opt_ignore_eq]
    call    prefix_match
    jc      check_ignore_sep
    mov     [rel value_arg_ptr], rdi
    call    parse_cli_uint
    jc      error_invalid_from_rbx
    mov     [rel ignore_count], rax
    jmp     next_arg

check_ignore_sep:
    mov     rdi, rbx
    lea     rsi, [rel opt_ignore]
    call    streq
    test    eax, eax
    jz      check_unknown_option
    inc     r13
    cmp     r13, r12
    jge     error_missing_ignore_arg
    mov     rbx, [rbp + r13*8 + 8]
    mov     rdi, rbx
    mov     [rel value_arg_ptr], rdi
    call    parse_cli_uint
    jc      error_invalid_from_rbx
    mov     [rel ignore_count], rax
    jmp     next_arg

check_unknown_option:
    cmp     byte [rbx], '-'
    jne     record_operand
    mov     rdi, rbx
    call    error_unknown_option
    mov     edi, 1
    jmp     exit_program

record_operand:
    cmp     qword [rel first_operand], 0
    jne     next_arg
    mov     [rel first_operand], rbx
    jmp     next_arg

set_endopts:
    mov     r14d, 1

next_arg:
    inc     r13
    jmp     parse_args

args_done:
    mov     rdi, [rel first_operand]
    test    rdi, rdi
    jz      compute_answer
    call    error_extra_operand
    mov     edi, 1
    jmp     exit_program

compute_answer:
    cmp     qword [rel flag_all], 0
    jne     mode_all

    lea     rsi, [rel env_omp_threads]
    call    find_env_value
    mov     rdi, rax
    call    parse_omp_threads
    mov     r13, rax

    lea     rsi, [rel env_omp_limit]
    call    find_env_value
    mov     rdi, rax
    call    parse_omp_threads
    mov     r14, rax

    test    r14, r14
    jnz     have_omp_limit
    mov     r14, ULONG_MAX
have_omp_limit:
    test    r13, r13
    jz      no_omp_override
    mov     rax, r13
    cmp     r14, rax
    cmovb   rax, r14
    jmp     apply_ignore

no_omp_override:
    mov     r15, r14
    cmp     r15, 1
    jbe     limit_ready
    call    cpu_quota
    cmp     rax, r15
    cmovb   r15, rax
limit_ready:
    cmp     r15, 1
    jbe     limit_is_answer
    call    get_current_count
    cmp     rax, r15
    cmovbe  r15, rax
    mov     rax, r15
    jmp     apply_ignore
limit_is_answer:
    mov     rax, r15
    jmp     apply_ignore

mode_all:
    call    get_installed_count

apply_ignore:
    mov     rbx, [rel ignore_count]
    cmp     rax, rbx
    jbe     force_one
    sub     rax, rbx
    jmp     print_count
force_one:
    mov     eax, 1

print_count:
    call    write_uint_stdout
    xor     edi, edi
    jmp     exit_program

print_help:
    mov     edi, STDOUT
    lea     rsi, [rel help_text]
    call    write_z
    xor     edi, edi
    jmp     exit_program

print_version:
    mov     edi, STDOUT
    lea     rsi, [rel version_text]
    call    write_z
    xor     edi, edi
    jmp     exit_program

error_missing_ignore_arg:
    call    error_missing_argument
    mov     edi, 1
    jmp     exit_program

error_invalid_from_rbx:
    mov     rdi, [rel value_arg_ptr]
    call    error_invalid_number
    mov     edi, 1

exit_program:
    mov     eax, SYS_EXIT
    syscall

write_uint_stdout:
    lea     rsi, [rel numbuf + 20]
    xor     ecx, ecx
    mov     r8, 10
    mov     rdx, rax
.loop:
    mov     rax, rdx
    xor     edx, edx
    div     r8
    add     dl, '0'
    mov     [rsi], dl
    dec     rsi
    inc     rcx
    mov     rdx, rax
    test    rax, rax
    jnz     .loop
    inc     rsi
    mov     byte [rsi + rcx], 10
    inc     rcx
    mov     edi, STDOUT
    mov     rdx, rcx
    call    write_fd_len
    ret

get_current_count:
    call    get_affinity_count
    test    rax, rax
    jnz     .done
    lea     rdi, [rel path_cpu_online]
    call    read_range_file
    test    rax, rax
    jnz     .done
    call    count_proc_stat_cpus
    test    rax, rax
    jnz     .done
    mov     eax, 1
.done:
    ret

get_installed_count:
    lea     rdi, [rel path_cpu_possible]
    call    read_range_file
    test    rax, rax
    jnz     .have_count
    call    count_proc_stat_cpus
    test    rax, rax
    jnz     .have_count
    mov     eax, 1
.have_count:
    cmp     rax, 2
    ja      .done
    mov     rbx, rax
    call    get_affinity_count
    cmp     rax, rbx
    cmova   rbx, rax
    mov     rax, rbx
.done:
    ret

cpu_quota:
    mov     eax, SYS_SCHED_GETSCHEDULER
    xor     edi, edi
    syscall
    test    rax, rax
    js      .none
    cmp     eax, SCHED_FIFO
    je      .none
    cmp     eax, SCHED_RR
    je      .none
    cmp     eax, SCHED_DEADLINE
    je      .none
    jmp     get_cgroup2_cpu_quota
.none:
    mov     rax, ULONG_MAX
    ret

get_cgroup2_cpu_quota:
    push    rbx
    push    r12
    push    r13

    lea     rdi, [rel path_proc_self_cgroup]
    lea     rsi, [rel cgroupbuf]
    mov     edx, PATHBUF_SIZE - 1
    call    read_file_once
    test    rax, rax
    jz      .none

    lea     rdi, [rel cgroupbuf]
    call    find_unified_cgroup
    test    rax, rax
    jz      .none
    mov     r12, rax

    call    find_cgroup2_mount
    test    rax, rax
    jz      .none

    mov     r13, ULONG_MAX
.quota_loop:
    cmp     byte [r12], 0
    je      .done

    lea     rdi, [rel pathbuf]
    lea     rsi, [rel mountbuf]
    call    append_z
    mov     rsi, r12
    call    append_z
    lea     rsi, [rel suffix_cpu_max]
    call    append_z

    lea     rdi, [rel pathbuf]
    lea     rsi, [rel filebuf]
    mov     edx, FILEBUF_SIZE - 1
    call    read_file_once
    test    rax, rax
    jz      .parent

    cmp     byte [rel filebuf + 0], 'm'
    jne     .parse_cpu_max
    cmp     byte [rel filebuf + 1], 'a'
    jne     .parse_cpu_max
    cmp     byte [rel filebuf + 2], 'x'
    je      .parent

.parse_cpu_max:
    lea     rdi, [rel filebuf]
    call    parse_cpu_max_pair
    jc      .parent
    test    rdx, rdx
    jz      .parent
    mov     rbx, rdx
    mov     rcx, rdx
    shr     rcx, 1
    add     rax, rcx
    xor     edx, edx
    div     rbx
    test    rax, rax
    jnz     .have_quota
    mov     eax, 1
.have_quota:
    cmp     r13, ULONG_MAX
    je      .store_quota
    cmp     rax, r13
    jae     .parent
.store_quota:
    mov     r13, rax
    cmp     r13, 1
    je      .done

.parent:
    mov     rdi, r12
    call    find_last_slash
    test    rax, rax
    jz      .done
    cmp     rax, r12
    jne     .trim_last
    cmp     byte [r12 + 1], 0
    je      .trim_last
    mov     byte [r12 + 1], 0
    jmp     .quota_loop
.trim_last:
    mov     byte [rax], 0
    jmp     .quota_loop

.done:
    mov     rax, r13
    jmp     .out
.none:
    mov     rax, ULONG_MAX
.out:
    pop     r13
    pop     r12
    pop     rbx
    ret

find_cgroup2_mount:
    push    rbx

    lea     rdi, [rel path_cgroup2_ctrl]
    call    file_exists
    test    eax, eax
    jz      .scan_mounts
    lea     rdi, [rel mountbuf]
    lea     rsi, [rel path_cgroup2_default]
    call    append_z
    lea     rax, [rel mountbuf]
    pop     rbx
    ret

.scan_mounts:
    lea     rdi, [rel path_proc_mounts]
    lea     rsi, [rel filebuf]
    mov     edx, FILEBUF_SIZE - 1
    call    read_file_once
    test    rax, rax
    jz      .fail

    lea     rbx, [rel filebuf]
.line:
    cmp     byte [rbx], 0
    je      .fail

    mov     rdi, rbx
    call    advance_token
    mov     rbx, rax
    cmp     byte [rbx], 0
    je      .fail
    cmp     byte [rbx], 10
    je      .next_line

    mov     rdi, rbx
    call    skip_spaces
    mov     rbx, rdi
    mov     r8, rbx
    call    advance_token
    mov     rbx, rax
    cmp     byte [rbx], 0
    je      .fail
    cmp     byte [rbx], 10
    je      .next_line

    mov     rdi, rbx
    call    skip_spaces
    mov     rbx, rdi
    mov     rdi, rbx
    lea     rsi, [rel str_cgroup2]
    call    streq_token
    test    eax, eax
    jz      .skip_line

    mov     rsi, r8
    lea     rdi, [rel mountbuf]
    mov     edx, PATHBUF_SIZE - 1
    call    copy_token_unescape
    jc      .fail
    lea     rax, [rel mountbuf]
    pop     rbx
    ret

.skip_line:
    mov     rdi, rbx
    call    skip_to_eol
    mov     rbx, rdi
    cmp     byte [rbx], 0
    je      .fail
.next_line:
    inc     rbx
    jmp     .line

.fail:
    xor     eax, eax
    pop     rbx
    ret

find_unified_cgroup:
    mov     rbx, rdi
.line:
    cmp     byte [rbx], 0
    je      .not_found
    cmp     byte [rbx + 0], '0'
    jne     .skip
    cmp     byte [rbx + 1], ':'
    jne     .skip
    cmp     byte [rbx + 2], ':'
    jne     .skip
    cmp     byte [rbx + 3], '/'
    jne     .skip
    lea     rax, [rbx + 3]
    mov     rdi, rax
.terminate:
    cmp     byte [rdi], 0
    je      .found
    cmp     byte [rdi], 10
    je      .zap_nl
    inc     rdi
    jmp     .terminate
.zap_nl:
    mov     byte [rdi], 0
.found:
    ret
.skip:
    mov     rdi, rbx
    call    skip_to_eol
    mov     rbx, rdi
    cmp     byte [rbx], 0
    je      .not_found
    inc     rbx
    jmp     .line
.not_found:
    xor     eax, eax
    ret

find_last_slash:
    xor     eax, eax
.loop:
    mov     dl, [rdi]
    test    dl, dl
    jz      .done
    cmp     dl, '/'
    jne     .next
    mov     rax, rdi
.next:
    inc     rdi
    jmp     .loop
.done:
    ret

copy_token_unescape:
    xor     ecx, ecx
.loop:
    mov     al, [rsi]
    test    al, al
    jz      .done
    cmp     al, ' '
    je      .done
    cmp     al, 10
    je      .done
    cmp     al, '\'
    jne     .copy_plain
    movzx   eax, byte [rsi + 1]
    sub     eax, '0'
    cmp     eax, 7
    ja      .copy_plain
    movzx   r8d, byte [rsi + 2]
    sub     r8d, '0'
    cmp     r8d, 7
    ja      .copy_plain
    movzx   r9d, byte [rsi + 3]
    sub     r9d, '0'
    cmp     r9d, 7
    ja      .copy_plain
    cmp     rcx, rdx
    jae     .fail
    lea     eax, [rax*8 + r8]
    lea     eax, [rax*8 + r9]
    mov     [rdi + rcx], al
    inc     rcx
    add     rsi, 4
    jmp     .loop
.copy_plain:
    cmp     rcx, rdx
    jae     .fail
    mov     [rdi + rcx], al
    inc     rcx
    inc     rsi
    jmp     .loop
.done:
    mov     byte [rdi + rcx], 0
    clc
    ret
.fail:
    stc
    ret

get_affinity_count:
    push    rbx
    push    r12
    push    r13

    mov     r12, AFFINITY_BYTES_INIT
.alloc:
    mov     eax, SYS_MMAP
    xor     edi, edi
    mov     rsi, r12
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1
    xor     r9d, r9d
    syscall
    test    rax, rax
    js      .fail
    mov     r13, rax

    mov     eax, SYS_SCHED_GETAFFINITY
    xor     edi, edi
    mov     rsi, r12
    mov     rdx, r13
    syscall
    test    rax, rax
    jg      .count
    cmp     rax, -EINVAL
    jne     .unmap_fail

    mov     eax, SYS_MUNMAP
    mov     rdi, r13
    mov     rsi, r12
    syscall
    shl     r12, 1
    jc      .fail
    jmp     .alloc

.count:
    mov     rcx, rax
    mov     rsi, r13
    xor     ebx, ebx
.qword:
    cmp     rcx, 8
    jb      .tail
    mov     rdi, [rsi]
    call    popcnt64
    add     rbx, rax
    add     rsi, 8
    sub     rcx, 8
    jmp     .qword
.tail:
    test    rcx, rcx
    jz      .unmap_success
.byte:
    movzx   edi, byte [rsi]
    call    popcnt8
    add     rbx, rax
    inc     rsi
    dec     rcx
    jnz     .byte

.unmap_success:
    mov     eax, SYS_MUNMAP
    mov     rdi, r13
    mov     rsi, r12
    syscall
    mov     rax, rbx
    jmp     .out

.unmap_fail:
    mov     eax, SYS_MUNMAP
    mov     rdi, r13
    mov     rsi, r12
    syscall
.fail:
    xor     eax, eax
.out:
    pop     r13
    pop     r12
    pop     rbx
    ret

count_proc_stat_cpus:
    push    rbx
    push    r12
    push    r13

    mov     eax, SYS_OPEN
    lea     rdi, [rel path_proc_stat]
    xor     esi, esi
    xor     edx, edx
    syscall
    test    rax, rax
    js      .fail
    mov     ebx, eax
    xor     r12d, r12d
    xor     r13d, r13d

.read:
    mov     eax, SYS_READ
    mov     edi, ebx
    lea     rsi, [rel filebuf]
    mov     edx, FILEBUF_SIZE
    syscall
    test    rax, rax
    jle     .close
    mov     rcx, rax
    lea     rsi, [rel filebuf]

.scan:
    mov     al, [rsi]
    cmp     r12d, 0
    jne     .state1
    cmp     al, 'c'
    je      .to_state1
    cmp     al, 10
    je      .next_char
    mov     r12d, 4
    jmp     .next_char
.state1:
    cmp     r12d, 1
    jne     .state2
    cmp     al, 'p'
    je      .to_state2
    cmp     al, 10
    je      .reset_state
    mov     r12d, 4
    jmp     .next_char
.state2:
    cmp     r12d, 2
    jne     .state3
    cmp     al, 'u'
    je      .to_state3
    cmp     al, 10
    je      .reset_state
    mov     r12d, 4
    jmp     .next_char
.state3:
    cmp     r12d, 3
    jne     .state4
    cmp     al, '0'
    jb      .cpu_not_digit
    cmp     al, '9'
    ja      .cpu_not_digit
    inc     r13
    mov     r12d, 4
    jmp     .next_char
.cpu_not_digit:
    cmp     al, 10
    je      .reset_state
    mov     r12d, 4
    jmp     .next_char
.state4:
    cmp     al, 10
    jne     .next_char
    xor     r12d, r12d
    jmp     .next_char

.to_state1:
    mov     r12d, 1
    jmp     .next_char
.to_state2:
    mov     r12d, 2
    jmp     .next_char
.to_state3:
    mov     r12d, 3
    jmp     .next_char
.reset_state:
    xor     r12d, r12d
.next_char:
    inc     rsi
    dec     rcx
    jnz     .scan
    jmp     .read

.close:
    mov     eax, SYS_CLOSE
    mov     edi, ebx
    syscall
    mov     rax, r13
    jmp     .out
.fail:
    xor     eax, eax
.out:
    pop     r13
    pop     r12
    pop     rbx
    ret

read_range_file:
    push    rdi
    lea     rsi, [rel filebuf]
    mov     edx, FILEBUF_SIZE - 1
    call    read_file_once
    test    rax, rax
    jz      .fail
    lea     rdi, [rel filebuf]
    call    parse_cpu_ranges
    pop     rdi
    ret
.fail:
    pop     rdi
    xor     eax, eax
    ret

parse_cpu_ranges:
    xor     r10d, r10d
.loop:
    movzx   eax, byte [rdi]
    sub     eax, '0'
    cmp     eax, 9
    ja      .done

    call    parse_uint_prefix
    jc      .fail
    mov     r9, rax
    cmp     byte [rdi], '-'
    jne     .single
    inc     rdi
    call    parse_uint_prefix
    jc      .fail
    cmp     rax, r9
    jb      .fail
    sub     rax, r9
    inc     rax
    add     r10, rax
    jmp     .sep
.single:
    inc     r10
.sep:
    cmp     byte [rdi], ','
    jne     .done
    inc     rdi
    jmp     .loop
.done:
    mov     rax, r10
    ret
.fail:
    xor     eax, eax
    ret

find_env_value:
    push    rbx
    mov     rbx, [rel envp_ptr]
.loop:
    mov     rdi, [rbx]
    test    rdi, rdi
    jz      .not_found
    push    rsi
    call    prefix_match
    jc      .next
    add     rsp, 8
    mov     rax, rdi
    pop     rbx
    ret
.next:
    pop     rsi
    add     rbx, 8
    jmp     .loop
.not_found:
    xor     eax, eax
    pop     rbx
    ret

parse_cli_uint:
    call    skip_spaces
    cmp     byte [rdi], '+'
    jne     .digits
    inc     rdi
.digits:
    call    parse_uint_prefix
    jc      .fail
    cmp     byte [rdi], 0
    jne     .fail
    clc
    ret
.fail:
    stc
    ret

parse_omp_threads:
    test    rdi, rdi
    jz      .invalid
    call    skip_spaces
    call    parse_uint_prefix
    jc      .invalid
    mov     r8, rax
    call    skip_spaces
    cmp     byte [rdi], 0
    je      .valid
    cmp     byte [rdi], ','
    je      .valid
.invalid:
    xor     eax, eax
    ret
.valid:
    mov     rax, r8
    ret

parse_cpu_max_pair:
    call    skip_spaces
    call    parse_uint_prefix
    jc      .fail
    mov     r10, rax
    mov     r9, rdi
    call    skip_spaces
    cmp     rdi, r9
    je      .fail
    call    parse_uint_prefix
    jc      .fail
    mov     rdx, rax
    mov     rax, r10
    clc
    ret
.fail:
    stc
    ret

parse_uint_prefix:
    xor     eax, eax
    movzx   edx, byte [rdi]
    sub     edx, '0'
    cmp     edx, 9
    ja      .fail
.loop:
    movzx   r8d, byte [rdi]
    sub     r8d, '0'
    cmp     r8d, 9
    ja      .done
    lea     rax, [rax + rax*4]
    lea     rax, [r8 + rax*2]
    inc     rdi
    jmp     .loop
.done:
    clc
    ret
.fail:
    stc
    ret

skip_spaces:
.loop:
    mov     al, [rdi]
    cmp     al, ' '
    je      .step
    cmp     al, 9
    jb      .done
    cmp     al, 13
    ja      .done
.step:
    inc     rdi
    jmp     .loop
.done:
    ret

advance_token:
.loop:
    mov     al, [rdi]
    test    al, al
    jz      .done
    cmp     al, ' '
    je      .done
    cmp     al, 10
    je      .done
    inc     rdi
    jmp     .loop
.done:
    mov     rax, rdi
    ret

skip_to_eol:
.loop:
    cmp     byte [rdi], 0
    je      .done
    cmp     byte [rdi], 10
    je      .done
    inc     rdi
    jmp     .loop
.done:
    ret

streq_token:
.loop:
    mov     al, [rsi]
    test    al, al
    jz      .end
    cmp     al, [rdi]
    jne     .no
    inc     rdi
    inc     rsi
    jmp     .loop
.end:
    mov     al, [rdi]
    test    al, al
    jz      .yes
    cmp     al, ' '
    je      .yes
    cmp     al, 10
    je      .yes
.no:
    xor     eax, eax
    ret
.yes:
    mov     eax, 1
    ret

file_exists:
    push    rbx
    mov     eax, SYS_OPEN
    xor     esi, esi
    xor     edx, edx
    syscall
    test    rax, rax
    js      .no
    mov     ebx, eax
    mov     eax, SYS_CLOSE
    mov     edi, ebx
    syscall
    mov     eax, 1
    pop     rbx
    ret
.no:
    xor     eax, eax
    pop     rbx
    ret

read_file_once:
    push    rbx
    push    r12

    mov     r12, rsi
    mov     rbx, rdx
    mov     eax, SYS_OPEN
    xor     esi, esi
    xor     edx, edx
    syscall
    test    rax, rax
    js      .fail
    mov     edi, eax
    mov     r10d, eax

    mov     eax, SYS_READ
    mov     edi, r10d
    mov     rsi, r12
    mov     rdx, rbx
    syscall
    mov     r11, rax

    mov     eax, SYS_CLOSE
    mov     edi, r10d
    syscall

    test    r11, r11
    jle     .fail
    mov     byte [r12 + r11], 0
    mov     rax, r11
    pop     r12
    pop     rbx
    ret
.fail:
    xor     eax, eax
    pop     r12
    pop     rbx
    ret

error_missing_argument:
    call    write_prog_prefix
    mov     edi, STDERR
    lea     rsi, [rel msg_requires_arg]
    call    write_z
    mov     edi, STDERR
    lea     rsi, [rel msg_try_help]
    call    write_z
    ret

error_invalid_number:
    push    rdi
    call    write_prog_prefix
    mov     edi, STDERR
    lea     rsi, [rel msg_invalid_number]
    call    write_z
    mov     edi, STDERR
    lea     rsi, [rel quote]
    call    write_z
    pop     rsi
    mov     edi, STDERR
    call    write_z
    mov     edi, STDERR
    lea     rsi, [rel quote_nl]
    call    write_z
    ret

error_extra_operand:
    push    rdi
    call    write_prog_prefix
    mov     edi, STDERR
    lea     rsi, [rel msg_extra_operand]
    call    write_z
    mov     edi, STDERR
    lea     rsi, [rel quote]
    call    write_z
    pop     rsi
    mov     edi, STDERR
    call    write_z
    mov     edi, STDERR
    lea     rsi, [rel quote_nl]
    call    write_z
    mov     edi, STDERR
    lea     rsi, [rel msg_try_help]
    call    write_z
    ret

error_unknown_option:
    push    rdi
    call    write_prog_prefix
    mov     edi, STDERR
    lea     rsi, [rel msg_unknown_option]
    call    write_z
    mov     edi, STDERR
    lea     rsi, [rel quote]
    call    write_z
    pop     rsi
    mov     edi, STDERR
    call    write_z
    mov     edi, STDERR
    lea     rsi, [rel quote_nl]
    call    write_z
    mov     edi, STDERR
    lea     rsi, [rel msg_try_help]
    call    write_z
    ret

write_prog_prefix:
    mov     edi, STDERR
    lea     rsi, [rel prog_prefix]
    call    write_z
    ret

write_fd_len:
    mov     eax, SYS_WRITE
    syscall
    ret

write_z:
    push    rdi
    push    rsi
    mov     rdi, rsi
    call    strlen_z
    mov     rdx, rax
    pop     rsi
    pop     rdi
    jmp     write_fd_len

strlen_z:
    xor     eax, eax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     rax
    jmp     .loop
.done:
    ret

append_z:
.loop:
    mov     al, [rsi]
    mov     [rdi], al
    inc     rdi
    inc     rsi
    test    al, al
    jnz     .loop
    dec     rdi
    ret

streq:
.loop:
    mov     al, [rdi]
    mov     dl, [rsi]
    cmp     al, dl
    jne     .no
    test    al, al
    je      .yes
    inc     rdi
    inc     rsi
    jmp     .loop
.no:
    xor     eax, eax
    ret
.yes:
    mov     eax, 1
    ret

prefix_match:
    push    rdi
.loop:
    mov     dl, [rsi]
    test    dl, dl
    jz      .match
    cmp     dl, [rdi]
    jne     .fail
    inc     rdi
    inc     rsi
    jmp     .loop
.match:
    add     rsp, 8
    clc
    ret
.fail:
    pop     rdi
    stc
    ret

popcnt64:
    xor     eax, eax
    test    rdi, rdi
    jz      .done
.loop:
    lea     rdx, [rdi - 1]
    and     rdi, rdx
    inc     eax
    test    rdi, rdi
    jnz     .loop
.done:
    ret

popcnt8:
    xor     eax, eax
    test    edi, edi
    jz      .done
.loop:
    lea     edx, [rdi - 1]
    and     edi, edx
    inc     eax
    test    edi, edi
    jnz     .loop
.done:
    ret
