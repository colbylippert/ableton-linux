/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Unit test of the stack self-check's JIT prologue classifier (wine-trace.h:
 * jit_prologue_class, xlated_stack_depth).  Built and run by `make -C profiler/tracer test`
 * (and by tests/test_jit_classifier.py when a C compiler is available).  No root, no BPF.
 *
 * The REAL_* fixtures are the first bytes of JIT images captured on the CachyOS laptop
 * (kernel 7.2.9-2-cachyos PREEMPT(full), x86-64 JIT with IBT) with
 *   sudo -n build/wine-trace --self-check --dump-jit DIR        (normal build)
 *   sudo -n build/gate/wine-trace --self-check --dump-jit DIR   (make test-gate build)
 * i.e. wine_syscall_exit's main program (f0), its first subprogram (f1, bpf_usdt_arg) and a
 * frame-less subprogram (f3) of the normal build, and wine_syscall_exit of the
 * WT_SELFTEST_BIG_FRAME build, which the verifier put on the per-CPU private stack.
 */
#include <linux/types.h>
#include <stdio.h>
#include <string.h>

#include "../wine-trace.h"

/* kernel stack: endbr64; nop5; nop3; push rbp; mov rbp,rsp; endbr64; sub rsp,8; push rbx/r13/r14/r15 */
static const char REAL_KERNEL_MAIN[] =
	"f3 0f 1e fa 0f 1f 44 00 00 0f 1f 00 55 48 89 e5 f3 0f 1e fa 48 81 ec 08 00 00 00 53 41 55 41 56 41 57 "
	"49 89 fd e8 ea 5d a2 d0 89 45 fc 48 bf 00 20 fa c3 a8 d0 ff ff 8b 77 24 8b 7f 0c 48 89 ee 48 83 c6 fc "
	"48 bf 00 c8 5e 04 c7 8d ff ff e8 b1 e2 51 d0 48 85 c0 74 04 48 83 c0 38 48 89 c3 48";

/* kernel stack, subprogram (bpf_usdt_arg): sub rsp,0x18 */
static const char REAL_KERNEL_SUBPROG[] =
	"f3 0f 1e fa 0f 1f 44 00 00 0f 1f 00 55 48 89 e5 f3 0f 1e fa 48 81 ec 18 00 00 00 53 41 55 41 56 41 57 "
	"48 89 d3 49 89 f7 49 89 fd 31 ff 48 89 7b 00 48 bf 00 e0 fc c3 a8 d0 ff ff 48 0f b6 7f 00 4c 89 ef e8 "
	"a8 db 9c d0 41 be fd ff ff ff 89 45 ec 85 c0 0f 8c b0 01 00 00 48 89 ee 48 83 c6 ec";

/* no BPF frame at all: the callee-saved pushes are followed by body code */
static const char REAL_NO_FRAME[] =
	"f3 0f 1e fa 0f 1f 44 00 00 0f 1f 00 55 48 89 e5 f3 0f 1e fa 53 41 55 48 89 fb 48 89 de 48 83 c6 48 48 "
	"bf 00 2e 9a 69 c7 8d ff ff 48 81 c7 30 01 00 00 8b 46 00 48 83 f8 04 73 12 48 c1 e0 03 48 01 f8 48 8b "
	"40 00 48 85 c0 74 02 eb 02 31 c0 49 89 c5 4d 85 ed 0f 84 c8 00 00 00 4c 89 ef 48 89";

/* private stack: no sub rsp; pushes; movabs r9,<priv_frame_ptr>; add r9,gs:[this_cpu_off] */
static const char REAL_PRIVATE[] =
	"f3 0f 1e fa 0f 1f 44 00 00 0f 1f 00 55 48 89 e5 f3 0f 1e fa 53 41 55 41 56 41 57 49 b9 38 48 de d7 dd "
	"62 00 00 65 4c 03 0c 25 28 50 bc 93 48 89 fb 41 51 e8 ac 5d a2 d0 41 59 49 89 c5 45 89 69 fc 48 bf 00 "
	"60 c6 c5 a8 d0 ff ff 8b 7f 24 41 51 e8 0f d9 9e d0 41 59 89 c7 49 89 b9 78 ff ff ff";

/* synthetic variants of the documented layouts (arch/x86/net/bpf_jit_comp.c) */
static const char SYN_KERNEL_NO_IBT[] = "0f 1f 44 00 00 0f 1f 00 55 48 89 e5 48 81 ec 30 00 00 00 53 41 55";
static const char SYN_PRIVATE_NO_SMP[] = "0f 1f 44 00 00 0f 1f 00 55 48 89 e5 53 49 b9 00 11 22 33 44 55 66 77 48 89 fb";
static const char SYN_PRIVATE_ARENA[] =
	"0f 1f 44 00 00 0f 1f 00 55 48 89 e5 41 54 53 49 bc 00 00 00 00 01 00 00 00 49 b9 00 11 22 33 44 55 66 77 "
	"65 4c 03 0c 25 00 00 00 00";
static const char SYN_XOR_RAX_KERNEL[] = "0f 1f 44 00 00 48 31 c0 55 48 89 e5 48 81 ec 00 01 00 00";
/* a body that happens to contain "sub rsp" / "movabs r9" bytes after a frame-less prologue must
 * not be read as a prologue */
static const char SYN_BODY_LOOKALIKE[] = "0f 1f 44 00 00 0f 1f 00 55 48 89 e5 53 48 89 fb 48 81 ec 40 00 00 00 49 b9";
static const char SYN_NO_PUSH_RBP[] = "0f 1f 44 00 00 0f 1f 00 48 89 e5 48 81 ec 08 00 00 00";

static int fails;

static size_t unhex(const char *s, unsigned char *out, size_t cap)
{
	size_t n = 0;
	unsigned v;
	int k;

	while (*s && n < cap) {
		while (*s == ' ')
			s++;
		if (!*s)
			break;
		if (sscanf(s, "%2x%n", &v, &k) != 1)
			break;
		out[n++] = (unsigned char)v;
		s += k;
	}
	return n;
}

static void check_prologue(const char *name, const char *hex, int want, __u32 want_depth)
{
	unsigned char buf[256];
	size_t n = unhex(hex, buf, sizeof(buf));
	__u32 depth = 12345;
	int got = jit_prologue_class(buf, n, &depth);

	if (got == want && (want != JIT_STACK_KERNEL || depth == want_depth)) {
		printf("PASS %s: %s depth %u\n", name, jit_stack_class_name(got), depth);
	} else {
		printf("FAIL %s: got class %d depth %u, want class %d depth %u\n", name, got, depth, want, want_depth);
		fails++;
	}
}

static struct wt_bpf_insn insn(__u8 code, __u8 dst, __u8 src, __s16 off, __s32 imm)
{
	struct wt_bpf_insn i;

	i.code = code;
	i.regs = (__u8)((dst & 0x0f) | (src << 4));
	i.off = off;
	i.imm = imm;
	return i;
}

static void check_xlated(const char *name, const struct wt_bpf_insn *p, unsigned long n, int want_used, __u32 want_depth)
{
	__u32 d = 999;
	int used = xlated_stack_depth(p, n, &d);

	if (!!used == !!want_used && d == want_depth) {
		printf("PASS %s: uses_r10=%d depth %u\n", name, used, d);
	} else {
		printf("FAIL %s: uses_r10=%d depth %u, want %d / %u\n", name, used, d, want_used, want_depth);
		fails++;
	}
}

int main(void)
{
	struct wt_bpf_insn prog[8];

	check_prologue("real-kernel-stack-main", REAL_KERNEL_MAIN, JIT_STACK_KERNEL, 8);
	check_prologue("real-kernel-stack-subprog", REAL_KERNEL_SUBPROG, JIT_STACK_KERNEL, 0x18);
	check_prologue("real-no-frame", REAL_NO_FRAME, JIT_STACK_NONE, 0);
	check_prologue("real-private-stack", REAL_PRIVATE, JIT_STACK_PRIVATE, 0);
	check_prologue("syn-kernel-without-ibt", SYN_KERNEL_NO_IBT, JIT_STACK_KERNEL, 0x30);
	check_prologue("syn-private-without-smp", SYN_PRIVATE_NO_SMP, JIT_STACK_PRIVATE, 0);
	check_prologue("syn-private-with-arena", SYN_PRIVATE_ARENA, JIT_STACK_PRIVATE, 0);
	check_prologue("syn-tailcall-xor-rax", SYN_XOR_RAX_KERNEL, JIT_STACK_KERNEL, 0x100);
	check_prologue("syn-body-lookalike", SYN_BODY_LOOKALIKE, JIT_STACK_NONE, 0);
	check_prologue("syn-no-push-rbp", SYN_NO_PUSH_RBP, JIT_STACK_UNKNOWN, 0);
	check_prologue("empty", "", JIT_STACK_UNKNOWN, 0);

	/* *(u64 *)(r10 - 8) = r1; r0 = 0; exit */
	prog[0] = insn(0x7b, 10, 1, -8, 0);
	prog[1] = insn(0xb7, 0, 0, 0, 0);
	prog[2] = insn(0x95, 0, 0, 0, 0);
	check_xlated("xlated-stx-fp", prog, 3, 1, 8);
	/* r2 = r10; r2 += -40; call 1 (map lookup with a stack key) */
	prog[0] = insn(0xbf, 2, 10, 0, 0);
	prog[1] = insn(0x07, 2, 0, 0, -40);
	prog[2] = insn(0x85, 0, 0, 0, 1);
	check_xlated("xlated-fp-pointer", prog, 3, 1, 40);
	/* r1 = *(u32 *)(r10 - 4) */
	prog[0] = insn(0x61, 1, 10, -4, 0);
	check_xlated("xlated-ldx-fp", prog, 1, 1, 4);
	/* ld_imm64 r1 (two slots, the second has regs 0) ; r0 = *(u64 *)(r1 + 0); exit */
	prog[0] = insn(0x18, 1, 2, 0, 0x1000);
	prog[1] = insn(0x00, 0, 0, 0, 0);
	prog[2] = insn(0x79, 0, 1, 0, 0);
	prog[3] = insn(0x95, 0, 0, 0, 0);
	check_xlated("xlated-no-stack", prog, 4, 0, 0);
	/* lock *(u64 *)(r10 - 16) += r1 (atomic on the stack) */
	prog[0] = insn(0xdb, 10, 1, -16, 0);
	check_xlated("xlated-atomic-fp", prog, 1, 1, 16);

	printf("SUMMARY fails=%d\n", fails);
	return fails;
}
