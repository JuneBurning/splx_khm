/* Kernel Hook Module for Trend Micro ServerProtect for Linux  */
/* Copyright (C) 2007 Trend Micro Incorporated.                */

/*
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 * 
 */

/*  ===========================================================================
 #  The following code section (macro definitions) is copied from the
 #  linux/arch/x86_64/kernel/entry.S file. The copied code section ensures that
 #  the "execveHook" entry to be added will work properly. Locate the
 #  corresponding code section from your Linux kernel source.
 #  ===========================================================================
 */

/*
 *  linux/arch/x86_64/entry.S
 *
 *  Copyright (C) 1991, 1992  Linus Torvalds
 *  Copyright (C) 2000, 2001, 2002  Andi Kleen SuSE Labs
 *  Copyright (C) 2000  Pavel Machek <pavel@suse.cz>
 * 
 *  $Id$
 */

/*
 * entry.S contains the system-call and fault low-level handling routines.
 *
 * NOTE: This code handles signal-recognition, which happens every time
 * after an interrupt and after each system call.
 * 
 * Normal syscalls and interrupts don't save a full stack frame, this is 
 * only done for syscall tracing, signals or fork/exec et.al.
 * 
 * A note on terminology:	 
 * - top of stack: Architecture defined interrupt frame from SS to RIP 
 * at the top of the kernel process stack.	
 * - partial stack frame: partially saved registers upto R11.
 * - full stack frame: Like partial stack frame, but all register saved. 
 *	
 * TODO:	 
 * - schedule it carefully for the final hardware.
 */

#define ASSEMBLY 1

#include <linux/config.h>
#include <linux/linkage.h>
#include <asm/segment.h>
#include <asm/smp.h>
#include <asm/cache.h>
#include <asm/errno.h>
#include <asm/dwarf2.h>
#include <asm/calling.h>
#include <asm/offset.h>
#include <asm/msr.h>
#include <asm/unistd.h>
#include <asm/thread_info.h>
#include <asm/hw_irq.h>

	.code64

#ifdef CONFIG_PREEMPT
#define preempt_stop cli
#else
#define preempt_stop
#define retint_kernel retint_restore_args
#endif	
	
/*
 * C code is not supposed to know about undefined top of stack. Every time 
 * a C function with an pt_regs argument is called from the SYSCALL based 
 * fast path FIXUP_TOP_OF_STACK is needed.
 * RESTORE_TOP_OF_STACK syncs the syscall state after any possible ptregs
 * manipulation.
 */        	
		
	/* %rsp:at FRAMEEND */ 
	.macro FIXUP_TOP_OF_STACK tmp
	movq	%gs:pda_oldrsp,\tmp
	movq  	\tmp,RSP(%rsp)
	movq    $__USER_DS,SS(%rsp)
	movq    $__USER_CS,CS(%rsp)
	movq 	$-1,RCX(%rsp)
	movq	R11(%rsp),\tmp  /* get eflags */
	movq	\tmp,EFLAGS(%rsp)
	.endm

	.macro RESTORE_TOP_OF_STACK tmp,offset=0
	movq   RSP-\offset(%rsp),\tmp
	movq   \tmp,%gs:pda_oldrsp
	movq   EFLAGS-\offset(%rsp),\tmp
	movq   \tmp,R11-\offset(%rsp)
	.endm

	.macro FAKE_STACK_FRAME child_rip
	/* push in order ss, rsp, eflags, cs, rip */
	xorq %rax, %rax
	pushq %rax /* ss */
	CFI_ADJUST_CFA_OFFSET	8
	pushq %rax /* rsp */
	CFI_ADJUST_CFA_OFFSET	8
	CFI_OFFSET	rip,0
	pushq $(1<<9) /* eflags - interrupts on */
	CFI_ADJUST_CFA_OFFSET	8
	pushq $__KERNEL_CS /* cs */
	CFI_ADJUST_CFA_OFFSET	8
	pushq \child_rip /* rip */
	CFI_ADJUST_CFA_OFFSET	8
	CFI_OFFSET	rip,0
	pushq	%rax /* orig rax */
	CFI_ADJUST_CFA_OFFSET	8
	.endm

	.macro UNFAKE_STACK_FRAME
	addq $8*6, %rsp
	CFI_ADJUST_CFA_OFFSET	-(6*8)
	.endm

	.macro	CFI_DEFAULT_STACK
	CFI_ADJUST_CFA_OFFSET  (SS)
	CFI_OFFSET	r15,R15-SS
	CFI_OFFSET	r14,R14-SS
	CFI_OFFSET	r13,R13-SS
	CFI_OFFSET	r12,R12-SS
	CFI_OFFSET	rbp,RBP-SS
	CFI_OFFSET	rbx,RBX-SS
	CFI_OFFSET	r11,R11-SS
	CFI_OFFSET	r10,R10-SS
	CFI_OFFSET	r9,R9-SS
	CFI_OFFSET	r8,R8-SS
	CFI_OFFSET	rax,RAX-SS
	CFI_OFFSET	rcx,RCX-SS
	CFI_OFFSET	rdx,RDX-SS
	CFI_OFFSET	rsi,RSI-SS
	CFI_OFFSET	rdi,RDI-SS
	CFI_OFFSET	rsp,RSP-SS
	CFI_OFFSET	rip,RIP-SS
	.endm

/*  ===========================================================================
 #  The following code section is copied from the "execve" entry in the
 #  entry.S file with the modifications listed below:
 #  - Change the entry name "execve" to "execveHook"
 #  - Change the call of "sys_execve" to "execveHook_X86_64"
 #  - Change the symbol "int_ret_from_sys_call" to "*p_int_ret_from_sys_call"
 #  ===========================================================================
 */
/*
 * execve(). This function needs to use IRET, not SYSRET, to set up all state properly.
 *
 * C extern interface:
 *       extern long execve(char *name, char **argv, char **envp)
 *
 * asm input arguments:
 *      rdi:     name, rsi:      argv, rdx:      envp
 *
 * We want to fallback into:
 *      extern long sys_execve(char *name, char **argv,char **envp, struct pt_regs regs)
 *
 * do_sys_execve asm fallback arguments:
 *      rdi:     name, rsi:      argv, rdx:      envp, fake frame on the stack
 */
ENTRY(execveHook)
	CFI_STARTPROC
	popq %r11
	CFI_ADJUST_CFA_OFFSET	-8
	SAVE_REST
	movq %r11, %r15
	FIXUP_TOP_OF_STACK %r11
	call execveHook_X86_64
	GET_THREAD_INFO(%rcx)
	bt $TIF_IA32,threadinfo_flags(%rcx)
	jc exec_32bit
	RESTORE_TOP_OF_STACK %r11
	movq %r15, %r11
	RESTORE_REST
	push %r11
	ret

exec_32bit:
	CFI_ADJUST_CFA_OFFSET	REST_SKIP
	movq %rax,RAX(%rsp)
	RESTORE_REST
	jmp *p_int_ret_from_sys_call	
	CFI_ENDPROC


