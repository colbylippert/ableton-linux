/* SPDX-License-Identifier: GPL-2.0-only WITH Linux-syscall-note */
/*
 * ntsync-live: the profiler's additions to the ntsync uapi (profiler/kernel/ntsync-live). A stock module answers
 * NTSYNC_IOC_LIVE_GET_FEATURES with ENOTTY, which user space must read as "no features".
 */
#ifndef __NTSYNC_LIVE_H
#define __NTSYNC_LIVE_H

#include <linux/types.h>
#include <linux/ioctl.h>

#define NTSYNC_LIVE_VERSION		1
#define NTSYNC_LIVE_F_SPIN		0x1	/* in-kernel optimistic spin: parameters spin_ns, spin_comm, spin_rt */
#define NTSYNC_LIVE_F_EVENT_MMAP	0x2	/* stage 2 (LiveSync): an event's state word can be mapped */
#define NTSYNC_LIVE_F_WAIT_NOSPIN	0x4	/* stage 2: NTSYNC_WAIT_LIVE_NOSPIN is accepted */

/* wait flag (stage 2): never spin in the kernel, the caller already spun */
#define NTSYNC_WAIT_LIVE_NOSPIN		0x80000000

struct ntsync_live_features {
	__u32 version;
	__u32 features;
	__u32 word_layout;	/* 0 before stage 2; 1: the LiveSync state word */
	__u32 page_size;
	__u32 reserved[4];
};

#define NTSYNC_IOC_LIVE_GET_FEATURES	_IOR('N', 0xc0, struct ntsync_live_features)

#endif
