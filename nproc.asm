; small `nproc` clone for Linux/x86-64, written in NASM
; build with: nasm -f elf64 nproc.asm && ld -o nproc nproc.o
;
; understands:
;   --all
;   --ignore=N
;   --ignore N
;
; also pays attention to:
;   OMP_NUM_THREADS
;   OMP_THREAD_LIMIT
;
; Normal mode asks the kernel for the current affinity mask first.
; `--all` prefers `/sys/devices/system/cpu/online` instead.

; syscall numbers
%define SYS_READ                0
%define SYS_WRITE               1
%define SYS_OPEN                2
%define SYS_CLOSE               3
%define SYS_EXIT                60
%define SYS_SCHED_GETAFFINITY   204

%define STDOUT      1
%define O_RDONLY    0
%define MASK_BYTES  128                 ; enough room for 1024 CPUs

; fixed strings
section .rodata
    path_cpu_online: db '/sys/devices/system/cpu/online', 0
    pfx_all:         db '--all', 0
    pfx_ignore_eq:   db '--ignore=', 0
    pfx_ignore:      db '--ignore', 0
    pfx_omp_threads: db 'OMP_NUM_THREADS=', 0
    pfx_omp_limit:   db 'OMP_THREAD_LIMIT=', 0

; scratch buffers
section .bss
    cpumask:    resb MASK_BYTES
    filebuf:    resb 256
    numbuf:     resb 21

; code
section .text
    global _start

; Park the long-lived state in callee-saved registers so helper routines
; can be careless with the usual scratch ones.
;   rbp = original rsp, so argc/argv stay easy to reach
;   r12 = flags (bit 0 means `--all`)
;   r13 = value passed to `--ignore`
;   r14 = envp
;   r15 = argc
;   rbx = argv index at first, final CPU count later
_start:
    mov     rbp, rsp
    mov     r15, [rbp]                  ; argc
    lea     r14, [rbp + r15*8 + 16]     ; skip argv[] and its trailing null

    xor     r12d, r12d                  ; no flags yet
    xor     r13d, r13d                  ; default ignore count

    ; walk argv starting after the program name
    mov     ebx, 1
.parse_args:
    cmp     rbx, r15
    jge     .args_done
    mov     rdi, [rbp + rbx*8 + 8]      ; argv[i]

    ; exact `--all`
    lea     rsi, [rel pfx_all]
    call    .prefix_match
    jc      .not_all
    cmp     byte [rdi], 0               ; reject `--allxyz`
    jne     .not_all
    or      r12d, 1
    jmp     .next_arg
.not_all:

    ; `--ignore=N`
    mov     rdi, [rbp + rbx*8 + 8]      ; prefix_match advanced rdi last time
    lea     rsi, [rel pfx_ignore_eq]
    call    .prefix_match
    jc      .not_ignore_eq
    call    .parse_uint                 ; rdi already points at the number
    mov     r13d, eax
    jmp     .next_arg
.not_ignore_eq:

    ; plain `--ignore`, with the value in the next argv slot
    mov     rdi, [rbp + rbx*8 + 8]      ; reload rdi
    lea     rsi, [rel pfx_ignore]
    call    .prefix_match
    jc      .next_arg                   ; something else, keep moving
    cmp     byte [rdi], 0
    jne     .next_arg                   ; ignore `--ignoreXYZ`
    inc     rbx                         ; next argv entry should be the number
    cmp     rbx, r15
    jge     .args_done
    mov     rdi, [rbp + rbx*8 + 8]
    call    .parse_uint
    mov     r13d, eax

.next_arg:
    inc     rbx
    jmp     .parse_args
.args_done:

    ; pick a starting CPU count
    test    r12d, 1
    jnz     .mode_all

    ; Usual path: affinity mask first, then `/sys`, then fall back to 1.
    call    .get_affinity_count
    test    eax, eax
    jnz     .default_got
    call    .get_online_count
    test    eax, eax
    jnz     .default_got
    mov     eax, 1
.default_got:
    mov     ebx, eax

    ; If OMP_NUM_THREADS is set, it wins outright.
    lea     rsi, [rel pfx_omp_threads]
    call    .find_env_uint
    test    eax, eax
    jnz     .omp_override
    ; Otherwise OMP_THREAD_LIMIT can clamp the result.
    lea     rsi, [rel pfx_omp_limit]
    call    .find_env_uint
    test    eax, eax
    jz      .apply_ignore
    cmp     eax, ebx
    cmovb   ebx, eax                    ; keep the smaller value
    jmp     .apply_ignore
.omp_override:
    mov     ebx, eax
    jmp     .apply_ignore

.mode_all:
    ; `--all` flips the lookup order: `/sys` first, affinity second.
    call    .get_online_count
    test    eax, eax
    jnz     .all_got
    call    .get_affinity_count
    test    eax, eax
    jnz     .all_got
    mov     eax, 1
.all_got:
    mov     ebx, eax

    ; Don't let `--ignore` drive the answer below 1.
.apply_ignore:
    sub     ebx, r13d
    cmp     ebx, 1
    jge     .print
    mov     ebx, 1

    ; Write the decimal digits backward into `numbuf`, keep the newline at
    ; the end, then dump the finished slice to stdout.
.print:
    mov     eax, ebx
    lea     rdi, [rel numbuf + 20]
    mov     byte [rdi], 10              ; trailing newline
    mov     ecx, 1                      ; already counting that newline
    mov     r8d, 10
.itoa_loop:
    xor     edx, edx
    div     r8d
    add     dl, '0'
    dec     rdi
    mov     [rdi], dl
    inc     ecx
    test    eax, eax
    jnz     .itoa_loop

    ; write(STDOUT, buf, len)
    mov     rsi, rdi                    ; start of the rendered number
    mov     edx, ecx                    ; bytes to write
    mov     edi, STDOUT                 ; set fd after copying rdi into rsi
    mov     eax, SYS_WRITE
    syscall

    ; exit(0)
    mov     eax, SYS_EXIT
    xor     edi, edi
    syscall

; Checks whether `rdi` starts with the string in `rsi`.
; On success, carry is clear and `rdi` is left pointing just past the prefix.
; On failure, carry is set and `rdi` gets put back where it started.
.prefix_match:
    push    rdi
.pm_loop:
    mov     dl, [rsi]
    test    dl, dl
    jz      .pm_match
    cmp     dl, [rdi]
    jne     .pm_fail
    inc     rdi
    inc     rsi
    jmp     .pm_loop
.pm_match:
    add     rsp, 8                      ; discard saved rdi
    clc
    ret
.pm_fail:
    pop     rdi
    stc
    ret


; Parse an unsigned decimal number at `rdi`.
; Returns 0 if the first byte is not a digit.
; Stops as soon as the digits stop.
.parse_uint:
    xor     eax, eax
    mov     ecx, 10
.pu_loop:
    movzx   edx, byte [rdi]
    sub     edx, '0'
    cmp     edx, 9
    ja      .pu_done
    imul    eax, ecx
    add     eax, edx
    inc     rdi
    jmp     .pu_loop
.pu_done:
    ret


; Scan `envp` for a variable that starts with the prefix in `rsi`
; and parse the decimal value that comes after it.
.find_env_uint:
    push    rbx
    mov     rbx, r14
.feu_loop:
    mov     rdi, [rbx]
    test    rdi, rdi
    jz      .feu_notfound
    push    rsi                         ; prefix_match walks through it
    call    .prefix_match
    jc      .feu_nomatch
    ; matched: `rdi` now points right after the `=`
    add     rsp, 8                      ; discard saved rsi
    call    .parse_uint                 ; commas/newlines naturally stop parsing
    pop     rbx
    ret
.feu_nomatch:
    pop     rsi                         ; restore prefix
    add     rbx, 8
    jmp     .feu_loop
.feu_notfound:
    xor     eax, eax
    pop     rbx
    ret


; Ask the kernel which CPUs this process is allowed to run on and count
; the bits in that mask. Returns 0 if the syscall fails.
.get_affinity_count:
    mov     rax, SYS_SCHED_GETAFFINITY
    xor     edi, edi                    ; pid 0 means "this process"
    mov     esi, MASK_BYTES
    lea     rdx, [rel cpumask]
    syscall

    test    rax, rax
    jle     .gac_fail

    mov     rcx, rax                    ; actual bytes written into cpumask
    lea     rsi, [rel cpumask]
    xor     r8d, r8d                    ; running total

.gac_qword:
    cmp     rcx, 8
    jb      .gac_tail
    mov     rdi, [rsi]
    call    .popcnt64
    add     r8d, eax
    add     rsi, 8
    sub     rcx, 8
    jmp     .gac_qword

.gac_tail:
    test    rcx, rcx
    jz      .gac_done
.gac_byte:
    movzx   edi, byte [rsi]
    call    .popcnt8
    add     r8d, eax
    inc     rsi
    dec     rcx
    jnz     .gac_byte

.gac_done:
    mov     eax, r8d
    ret
.gac_fail:
    xor     eax, eax
    ret


; Read `/sys/devices/system/cpu/online`, which is usually something like
; `0-3,5,8-11`, and turn that into a count.
.get_online_count:
    mov     rax, SYS_OPEN
    lea     rdi, [rel path_cpu_online]
    xor     esi, esi                    ; O_RDONLY
    xor     edx, edx
    syscall
    test    rax, rax
    js      .goc_fail

    mov     r8, rax                     ; keep the fd around

    mov     rax, SYS_READ
    mov     edi, r8d
    lea     rsi, [rel filebuf]
    mov     edx, 255
    syscall
    push    rax                         ; keep read()'s return value across close()

    mov     rax, SYS_CLOSE
    mov     edi, r8d
    syscall

    pop     rcx                         ; bytes read
    test    rcx, rcx
    jle     .goc_fail

    lea     rdi, [rel filebuf]
    mov     byte [rdi + rcx], 0         ; make the parser's life easier
    call    .parse_cpu_ranges
    ret

.goc_fail:
    xor     eax, eax
    ret


; Count a `/sys` CPU range string like `0-3,5,8-11`.
; Each comma-separated chunk is either one CPU or an inclusive range.
.parse_cpu_ranges:
    xor     r8d, r8d                    ; total so far
.pcr_loop:
    movzx   eax, byte [rdi]
    sub     al, '0'
    cmp     al, 9
    ja      .pcr_done                   ; anything else means we're done

    call    .parse_uint
    mov     r9d, eax

    cmp     byte [rdi], '-'
    jne     .pcr_single
    inc     rdi                         ; skip the dash
    call    .parse_uint
    sub     eax, r9d
    inc     eax                         ; inclusive range
    add     r8d, eax
    jmp     .pcr_sep
.pcr_single:
    inc     r8d
.pcr_sep:
    cmp     byte [rdi], ','
    jne     .pcr_done
    inc     rdi
    jmp     .pcr_loop
.pcr_done:
    mov     eax, r8d
    ret


; Tiny bit counters using Kernighan's trick: keep clearing the lowest set
; bit until the value becomes zero.
.popcnt64:
    xor     eax, eax
    test    rdi, rdi
    jz      .popcnt64_done
.popcnt64_loop:
    lea     rdx, [rdi - 1]
    and     rdi, rdx
    inc     eax
    test    rdi, rdi
    jnz     .popcnt64_loop
.popcnt64_done:
    ret

.popcnt8:
    xor     eax, eax
    test    edi, edi
    jz      .popcnt8_done
.popcnt8_loop:
    lea     edx, [rdi - 1]
    and     edi, edx
    inc     eax
    test    edi, edi
    jnz     .popcnt8_loop
.popcnt8_done:
    ret
