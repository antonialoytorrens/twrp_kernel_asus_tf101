/*
 * arch/arm/mach-tegra/headsmp-t2.S
 *
 * SMP initialization routines for Tegra2 SoCs
 *
 * Copyright (c) 2009-2010, NVIDIA Corporation.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
 * more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

#include <linux/linkage.h>
#include <linux/init.h>

#include <asm/assembler.h>
#include <asm/domain.h>
#include <asm/ptrace.h>
#include <asm/cache.h>

#include <mach/iomap.h>
#include <mach/io.h>

#include "power-macros.S"

#define TTB_FLAGS 0x6A	@ IRGN_WBWA, OC_RGN_WBWA, S, NOS

#define PMC_DPD_SAMPLE	0x20
#define PMC_DPD_ENABLE	0x24
#define PMC_SCRATCH39	0x138

#define CLK_RESET_PLLX_BASE     0xe0
#define CLK_RESET_PLLX_MISC     0xe4
#define CLK_RESET_PLLP_BASE     0xa0
#define CLK_RESET_PLLP_OUTA     0xa4
#define CLK_RESET_PLLP_OUTB     0xa8
#define CLK_RESET_PLLP_MISC     0xac

/*        .section ".cpuinit.text", "ax"*/

/*
 *	__restart_plls
 *
 *	  Loads the saved PLLX and PLLP parameters into the PLLs, to
 *	  allow them to stabilize while the rest of the CPU state is restored.
 *	  Should be called after the MMU is enabled. Jumps directly
 *	  to __cortex_a9_restore
 */
	.align L1_CACHE_SHIFT
__restart_plls:
	mov32	r0, tegra_sctx
	mov32	r3, (TEGRA_CLK_RESET_BASE-IO_PPSB_PHYS+IO_PPSB_VIRT)
	mov32	r4, (TEGRA_TMRUS_BASE-IO_PPSB_PHYS+IO_PPSB_VIRT)

	ldr	r1, [r0, #0x0]	@ pllx_misc
	ldr	r2, [r0, #0x4]	@ pllx_base
	str	r1, [r3, #CLK_RESET_PLLX_MISC]
	str	r2, [r3, #CLK_RESET_PLLX_BASE]

	ldr	r1, [r0, #0x8]	@ pllp_misc
	ldr	r2, [r0, #0xc]	@ pllp_base
	str	r1, [r3, #CLK_RESET_PLLP_MISC]
	str	r2, [r3, #CLK_RESET_PLLP_BASE]

	ldr	r1, [r0, #0x10]	@ pllp_outa
	ldr	r2, [r0, #0x14]	@ pllp_outb
	str	r1, [r3, #CLK_RESET_PLLP_OUTA]
	str	r2, [r3, #CLK_RESET_PLLP_OUTB]

	/* record the time that PLLX and PLLP will be stable */
	ldr	r1, [r4]
	add	r1, r1, #300
	str	r1, [r0, #0x18]	@ pll_timeout
	/* FIXME: need to record actual power transition here */
	mov	r0, #0
	b	__cortex_a9_l2x0_restart
ENDPROC(__restart_plls)

/*
 *	tegra_lp2_startup
 *
 *	  Secondary CPU boot vector when restarting the master CPU following
 *	  an LP2 idle transition. Re-enable coresight access, re-enable
 *	  MMU, re-start PLLX, restore processor context.
 */
	.align L1_CACHE_SHIFT
ENTRY(tegra_lp2_startup)
	setmode PSR_F_BIT | PSR_I_BIT | SVC_MODE, r9

	mov32	r0, TEGRA_TMRUS_BASE
	ldr	r1, [r0]
	mov32	r0, TEGRA_PMC_BASE
	str	r1, [r0, #PMC_SCRATCH39]	@ save off exact lp2 exit time
	mov	r1, #0
	str	r1, [r0, #PMC_DPD_SAMPLE]
	str	r1, [r0, #PMC_DPD_ENABLE]

	bl	__invalidate_cpu_state
	bl	__enable_coresite_access

	mrc	p15, 0, r0, c1, c0, 1
	orr	r0, r0, #(1 << 6) | (1 << 0)	@ re-enable coherency
	mcr	p15, 0, r0, c1, c0, 1

	/* enable SCU */
	mov32	r0, TEGRA_ARM_PERIF_BASE
	ldr	r1, [r0]
	orr	r1, r1, #1
	str	r1, [r0]

	adr	r4, __tegra_lp2_data
	ldmia	r4, {r5, r7, r12}
	mov	r1, r12			@ ctx_restore = __cortex_a9_restore
	sub	r4, r4, r5
	ldr	r0, [r7, r4]		@ pgdir = tegra_pgd_phys
	b	__return_to_virtual
ENDPROC(tegra_lp2_startup)
	.type	__tegra_lp2_data, %object
__tegra_lp2_data:
	.long	.
	.long	tegra_pgd_phys
	.long	__restart_plls
	.size	__tegra_lp2_data, . - __tegra_lp2_data

#ifdef CONFIG_HOTPLUG_CPU
/*
 *	tegra_hotplug_startup
 *
 *	  Secondary CPU boot vector when restarting a CPU following a
 *	  hot-unplug. Uses the page table created by smp_prepare_cpus and
 *	  stored in tegra_pgd_phys as the safe page table for
 *	  __return_to_virtual, and jumps directly to __cortex_a9_restore.
 */
	.align L1_CACHE_SHIFT
ENTRY(tegra_hotplug_startup)
	setmode	PSR_F_BIT | PSR_I_BIT | SVC_MODE, r9
	bl	__invalidate_cpu_state
	enable_coresite r1

	/* most of the below is a retread of what happens in __v7_setup and
	 * secondary_startup, to get the MMU re-enabled and to branch
	 * to secondary_kernel_startup */
	mrc	p15, 0, r0, c1, c0, 1
	orr	r0, r0, #(1 << 6) | (1 << 0)	@ re-enable coherency
	mcr	p15, 0, r0, c1, c0, 1

	adr	r4, __tegra_hotplug_data
	ldmia	r4, {r5, r7, r12}
	mov	r1, r12			@ ctx_restore = __cortex_a9_restore
	sub	r4, r4, r5
	ldr	r0, [r7, r4]		@ pgdir = secondary_data.pgdir
	b	__return_to_virtual
ENDPROC(tegra_hotplug_startup)


	.type	__tegra_hotplug_data, %object
__tegra_hotplug_data:
	.long	.
	.long	tegra_pgd_phys
	.long	__cortex_a9_restore
	.size	__tegra_hotplug_data, . - __tegra_hotplug_data
#endif
