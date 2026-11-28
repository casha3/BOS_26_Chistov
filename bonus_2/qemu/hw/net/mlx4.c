/*
 * QEMU model of a Mellanox ConnectX-3 (mlx4) PCI function.
 *
 * The model implements the parts of the device that the Linux mlx4_core /
 * mlx4_en drivers touch while probing and while running administrative
 * (ethtool / netlink / sysfs) operations:
 *
 *   - PCI configuration space (vendor 15b3, device 1003), BAR0 (device
 *     configuration space) and BAR2 (UAR / doorbells), MSI-X with a legacy
 *     INTx fallback;
 *   - the Host Command Register (HCR) firmware command interface, polled and
 *     event driven (command completions are delivered through the async EQ);
 *   - the ownership semaphore, the reset block and the catastrophic error
 *     buffer;
 *   - ICM virtual -> physical translation (MAP_ICM), which is needed to find
 *     the async EQ buffer described by MTT entries;
 *   - canned but self-consistent answers for QUERY_FW / QUERY_DEV_CAP /
 *     QUERY_PORT / QUERY_ADAPTER, and "success" for object/port commands.
 *
 * There is no Ethernet data path: TX/RX descriptors are ignored on purpose.
 * The fuzzing target is the administrative surface of the driver, and the
 * device is also a "malicious device" test bench (property evil=on makes a
 * few answers inconsistent, see the README).
 *
 * Reference: drivers/net/ethernet/mellanox/mlx4/ in Linux and the public
 * ConnectX-3 programming notes; see docs/04_qemu_emulation.md.
 *
 * This file is portable C99/QOM code: it is built by QEMU for every host
 * (macOS/arm64 and Linux/x86_64 included), no host specific #ifdef is needed.
 *
 * Copyright (c) 2026.  GPLv2, like the rest of QEMU.
 */

#include "qemu/osdep.h"
#include "hw/pci/pci.h"
#include "hw/pci/pci_device.h"
#include "hw/pci/pci_ids.h"
#include "hw/pci/msix.h"
#include "hw/core/qdev-properties.h"
#include "migration/vmstate.h"
#include "qapi/error.h"
#include "qemu/bswap.h"
#include "qemu/log.h"
#include "qemu/module.h"
#include "qom/object.h"

#define TYPE_MLX4_DEVICE "mlx4"
OBJECT_DECLARE_SIMPLE_TYPE(Mlx4State, MLX4_DEVICE)

/* PCI IDs of the ConnectX-3 family handled by the mlx4 driver. */
#define MLX4_PCI_VENDOR_ID      0x15b3
#define MLX4_PCI_DEVICE_ID_CX3  0x1003  /* MT27500 family */

#define MLX4_BAR0_SIZE          (1024 * 1024)       /* DCS: HCR + registers  */
#define MLX4_BAR2_SIZE          (8 * 1024 * 1024)   /* UAR area, 2048 pages  */

#define MLX4_MSIX_VECTORS       64
#define MLX4_MSIX_TABLE_OFFSET  0x4000
#define MLX4_MSIX_PBA_OFFSET    0x5000

/* Fixed registers inside BAR0 (same layout as real firmware). */
#define MLX4_HCR_OFFSET         0x80680
#define MLX4_HCR_DWORDS         7
#define MLX4_OWNER_OFFSET       0x8069c
#define MLX4_RESET_BLOCK_OFFSET 0xf0000
#define MLX4_RESET_REG_OFFSET   (MLX4_RESET_BLOCK_OFFSET + 0x10)
#define MLX4_RESET_SEM_OFFSET   (MLX4_RESET_BLOCK_OFFSET + 0x3fc)

/* Firmware-described regions, the addresses are reported by QUERY_FW. */
#define MLX4_CLR_INT_OFFSET     0x1000
#define MLX4_CATAS_OFFSET       0x6000
#define MLX4_CATAS_SIZE_DWORDS  0x40

/* HCR layout, relative to MLX4_HCR_OFFSET. */
#define HCR_IN_HI       0
#define HCR_IN_LO       1
#define HCR_IN_MOD      2
#define HCR_OUT_HI      3
#define HCR_OUT_LO      4
#define HCR_TOKEN       5
#define HCR_CTRL        6

#define HCR_GO_BIT      23
#define HCR_E_BIT       22
#define HCR_T_BIT       21

/* Firmware command status codes (subset). */
#define CMD_STAT_OK          0x00
#define CMD_STAT_INTERNAL    0x01
#define CMD_STAT_BAD_OP      0x02
#define CMD_STAT_BAD_PARAM   0x03

/* Opcodes used by the driver (Linux include/linux/mlx4/cmd.h). */
#define CMD_QUERY_FW         0x004
#define CMD_QUERY_DEV_CAP    0x003
#define CMD_QUERY_ADAPTER    0x006
#define CMD_INIT_HCA         0x007
#define CMD_CLOSE_HCA        0x008
#define CMD_INIT_PORT        0x009
#define CMD_CLOSE_PORT       0x00a
#define CMD_SET_PORT         0x00c
#define CMD_SW2HW_MPT        0x00d
#define CMD_QUERY_MPT        0x00e
#define CMD_HW2SW_MPT        0x00f
#define CMD_READ_MTT         0x010
#define CMD_WRITE_MTT        0x011
#define CMD_MAP_EQ           0x012
#define CMD_SW2HW_EQ         0x013
#define CMD_HW2SW_EQ         0x014
#define CMD_QUERY_EQ         0x015
#define CMD_SW2HW_CQ         0x016
#define CMD_HW2SW_CQ         0x017
#define CMD_QUERY_CQ         0x018
#define CMD_RST2INIT_QP      0x019
#define CMD_INIT2RTR_QP      0x01a
#define CMD_RTR2RTS_QP       0x01b
#define CMD_RTS2RTS_QP       0x01c
#define CMD_SQERR2RTS_QP     0x01d
#define CMD_2ERR_QP          0x01e
#define CMD_RTS2SQD_QP       0x01f
#define CMD_SQD2RTS_QP       0x020
#define CMD_2RST_QP          0x021
#define CMD_QUERY_QP         0x022
#define CMD_CONF_SPECIAL_QP  0x023
#define CMD_MAD_IFC          0x024
#define CMD_READ_MCG         0x025
#define CMD_WRITE_MCG        0x026
#define CMD_MGID_HASH        0x027
#define CMD_MODIFY_CQ        0x02c
#define CMD_SYNC_TPT         0x02f
#define CMD_NOP              0x031
#define CMD_MOD_STAT_CFG     0x034
#define CMD_SW2HW_SRQ        0x035
#define CMD_HW2SW_SRQ        0x036
#define CMD_QUERY_SRQ        0x037
#define CMD_SQD2SQD_QP       0x038
#define CMD_ACCESS_REG       0x03b
#define CMD_ARM_SRQ          0x040
#define CMD_QUERY_PORT       0x043
#define CMD_SET_VLAN_FLTR    0x047
#define CMD_SET_MCAST_FLTR   0x048
#define CMD_DUMP_ETH_STATS   0x049
#define CMD_SENSE_PORT       0x04d
#define CMD_HW_HEALTH_CHECK  0x050
#define CMD_QUERY_FUNC       0x056
#define CMD_RUN_FW           0xff6
#define CMD_UNMAP_ICM        0xff9
#define CMD_MAP_ICM          0xffa
#define CMD_UNMAP_ICM_AUX    0xffb
#define CMD_MAP_ICM_AUX      0xffc
#define CMD_SET_ICM_SIZE     0xffd
#define CMD_UNMAP_FA         0xffe
#define CMD_MAP_FA           0xfff

#define MLX4_EVENT_TYPE_CMD  0x0a

#define MLX4_MAX_EQ          256
#define MLX4_MAX_ICM_RANGES  512
#define MLX4_MBOX_SIZE       4096

typedef struct Mlx4IcmRange {
    uint64_t va;
    uint64_t pa;
    uint64_t size;
} Mlx4IcmRange;

typedef struct Mlx4EqCtx {
    bool valid;
    uint8_t log_eq_size;
    uint8_t intr;       /* MSI-X vector number reported in the EQ context */
    uint64_t mtt_addr;  /* ICM virtual address of the first MTT entry */
    uint32_t prod;      /* number of events posted so far */
} Mlx4EqCtx;

struct Mlx4State {
    PCIDevice parent_obj;

    MemoryRegion bar0;
    MemoryRegion bar2;

    bool msix_ok;
    bool irq_asserted;

    /* HCR dwords, already byte-swapped to host order (bar0 is big endian) */
    uint32_t hcr[MLX4_HCR_DWORDS];

    /* Fixed registers */
    bool owned;
    uint32_t written_reset;

    /* Event queues as described by SW2HW_EQ */
    Mlx4EqCtx eqs[MLX4_MAX_EQ];
    int async_eqn;

    /* ICM virtual -> physical ranges from MAP_ICM */
    Mlx4IcmRange icm[MLX4_MAX_ICM_RANGES];
    unsigned num_icm;
    uint32_t mtt_entry_sz;
    uint64_t mtt_base;   /* ICM virtual base of the MTT table (INIT_HCA) */

    /* Properties */
    uint32_t num_ports;
    uint64_t def_mac;
    bool verbose;
    bool evil;
    bool msix;
};

static void mlx4_dbg(Mlx4State *s, const char *fmt, ...)
{
    va_list ap;

    if (!s->verbose) {
        return;
    }
    va_start(ap, fmt);
    fprintf(stderr, "mlx4: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}

static bool mlx4_dma_read(Mlx4State *s, uint64_t addr, void *buf, size_t len)
{
    return pci_dma_read(PCI_DEVICE(s), addr, buf, len) == MEMTX_OK;
}

static bool mlx4_dma_write(Mlx4State *s, uint64_t addr, const void *buf,
                           size_t len)
{
    return pci_dma_write(PCI_DEVICE(s), addr, buf, len) == MEMTX_OK;
}

/* ------------------------------------------------------------------ */
/* ICM virtual address space                                           */
/* ------------------------------------------------------------------ */

static void mlx4_icm_reset(Mlx4State *s)
{
    s->num_icm = 0;
}

static void mlx4_icm_add(Mlx4State *s, uint64_t va, uint64_t pa, uint64_t size)
{
    if (!size) {
        return;
    }
    if (s->num_icm == MLX4_MAX_ICM_RANGES) {
        mlx4_dbg(s, "ICM map is full, dropping range %#" PRIx64, va);
        return;
    }
    s->icm[s->num_icm].va = va;
    s->icm[s->num_icm].pa = pa;
    s->icm[s->num_icm].size = size;
    s->num_icm++;
    mlx4_dbg(s, "MAP_ICM va=%#" PRIx64 " pa=%#" PRIx64 " size=%#" PRIx64,
             va, pa, size);
}

static bool mlx4_icm_translate(Mlx4State *s, uint64_t va, uint64_t *pa)
{
    int i;

    /* Later mappings may split/override earlier ones: walk backwards. */
    for (i = (int)s->num_icm - 1; i >= 0; i--) {
        Mlx4IcmRange *r = &s->icm[i];

        if (va >= r->va && va - r->va < r->size) {
            *pa = r->pa + (va - r->va);
            return true;
        }
    }
    return false;
}

/* ------------------------------------------------------------------ */
/* Event queue                                                         */
/* ------------------------------------------------------------------ */

static void mlx4_raise_irq(Mlx4State *s, unsigned vector)
{
    PCIDevice *pci = PCI_DEVICE(s);

    if (s->msix_ok && msix_enabled(pci)) {
        mlx4_dbg(s, "IRQ via MSI-X vector %u", vector);
        msix_notify(pci, vector);
        return;
    }
    /* Legacy INTx: level triggered, cleared by a CLR_INT register write. */
    if (!s->irq_asserted) {
        s->irq_asserted = true;
        mlx4_dbg(s, "IRQ via INTx");
        pci_irq_assert(pci);
    } else {
        mlx4_dbg(s, "IRQ suppressed, INTx already asserted");
    }
}

/*
 * When firmware hands an EQ to the driver (SW2HW_EQ), it must initialize the
 * ownership bits of the ring: an entry whose owner bit matches the current
 * ring phase is considered valid by mlx4_eq_int().  Unwritten entries must
 * therefore carry the opposite bit.  With a ring of nent entries the phase is
 * (cons_index & nent), so the first half starts with 0x80 and the second half
 * with 0x00.
 */
static void mlx4_eq_ring_init(Mlx4State *s, unsigned int eqn)
{
    Mlx4EqCtx *eq = &s->eqs[eqn];
    uint8_t page_buf[4096];
    uint32_t nent = 1u << eq->log_eq_size;
    uint32_t entries_per_page = 4096 / 32;
    uint32_t npages = (nent * 32 + 4095) / 4096;
    uint32_t page;
    unsigned int i;

    for (page = 0; page < npages; page++) {
        uint32_t first = page * entries_per_page;
        uint8_t owner = (first & nent) ? 0x00 : 0x80;
        uint64_t mtt_va = s->mtt_base + eq->mtt_addr +
                          (uint64_t)page * s->mtt_entry_sz;
        uint64_t mtt_pa, entry, page_pa;
        uint8_t raw[8];

        memset(page_buf, 0, sizeof(page_buf));
        for (i = 0; i < entries_per_page; i++) {
            page_buf[i * 32 + 31] = owner;   /* struct mlx4_eqe.owner */
        }
        if (!mlx4_icm_translate(s, mtt_va, &mtt_pa) ||
            !mlx4_dma_read(s, mtt_pa, raw, sizeof(raw))) {
            mlx4_dbg(s, "cannot read MTT entry for EQ %u page %u", eqn, page);
            return;
        }
        entry = ldq_be_p(raw);
        if (!(entry & 1)) {
            mlx4_dbg(s, "MTT entry for EQ %u page %u is not present", eqn, page);
            return;
        }
        page_pa = entry & ~0xfffULL;
        if (!mlx4_dma_write(s, page_pa, page_buf, sizeof(page_buf))) {
            mlx4_dbg(s, "cannot initialize EQ %u page %u", eqn, page);
            return;
        }
    }
    mlx4_dbg(s, "EQ %u ring initialized: nent=%u", eqn, nent);
}

/*
 * Post a command completion event to the asynchronous EQ.
 *
 * mlx4_eqe layout (32 bytes, see include/linux/mlx4/device.h):
 *   [0] ownership bit 0x80, [1] type, [3] subtype,
 *   [6..7] token (be16), [15] status, [16..23] out_param (be64).
 *
 * The EQ buffer is addressed through MTT entries: the EQ context obtained
 * from SW2HW_EQ contains the ICM virtual address of the first MTT entry, and
 * each MTT entry holds the physical address of one EQ page.
 */
static void mlx4_eqe_post_cmd(Mlx4State *s, uint16_t token, uint8_t status,
                              uint64_t out_param)
{
    Mlx4EqCtx *eq;
    uint8_t eqe[32];
    uint8_t raw[8];
    uint64_t entry, mtt_pa;
    uint64_t page_pa;
    uint32_t idx, nent, page, poff;
    uint64_t mtt_va;

    if (s->async_eqn < 0 || s->async_eqn >= MLX4_MAX_EQ ||
        !s->eqs[s->async_eqn].valid) {
        mlx4_dbg(s, "no async EQ, cannot complete command %#x (status %#x)",
                 token, status);
        return;
    }
    eq = &s->eqs[s->async_eqn];
    if (!eq->log_eq_size || eq->log_eq_size > 20) {
        mlx4_dbg(s, "bad async EQ log size %u", eq->log_eq_size);
        return;
    }

    idx = eq->prod;
    nent = 1u << eq->log_eq_size;

    memset(eqe, 0, sizeof(eqe));
    eqe[31] = (idx & nent) ? 0x80 : 0x00;  /* struct mlx4_eqe.owner */
    eqe[1] = MLX4_EVENT_TYPE_CMD;
    stw_be_p(eqe + 6, token);
    eqe[15] = status;
    stq_be_p(eqe + 16, out_param);

    page = (idx * 32) >> 12;
    poff = (idx * 32) & 0xfff;
    mtt_va = s->mtt_base + eq->mtt_addr + (uint64_t)page * s->mtt_entry_sz;

    if (!mlx4_icm_translate(s, mtt_va, &mtt_pa)) {
        mlx4_dbg(s, "cannot translate MTT entry at %#" PRIx64, mtt_va);
        return;
    }
    if (!mlx4_dma_read(s, mtt_pa, raw, sizeof(raw))) {
        mlx4_dbg(s, "cannot read MTT entry at %#" PRIx64, mtt_pa);
        return;
    }
    entry = ldq_be_p(raw);
    if (!(entry & 1)) {          /* MLX4_MTT_FLAG_PRESENT */
        mlx4_dbg(s, "MTT entry %#x is not present", (unsigned)page);
        return;
    }
    page_pa = entry & ~0xfffULL;

    if (!mlx4_dma_write(s, page_pa + poff, eqe, sizeof(eqe))) {
        mlx4_dbg(s, "cannot write EQE at %#" PRIx64, page_pa + poff);
        return;
    }

    eq->prod = idx + 1;
    mlx4_dbg(s, "EQE cmd token=%#x status=%#x -> eqn %d idx %u pa=%#" PRIx64
             " off=%#x", token, status, s->async_eqn, idx, page_pa + poff, poff);
    mlx4_raise_irq(s, eq->intr);
}

/* ------------------------------------------------------------------ */
/* Firmware command implementation                                     */
/* ------------------------------------------------------------------ */

static void mlx4_fill_query_fw(Mlx4State *s, uint8_t *mb)
{
    /*
     * The driver reads a be64 at 0x00: the high 16 bits are the firmware
     * area size in pages, the rest is the version (major/sub-minor/minor).
     * Version 2.42.5000 as printed by the driver.
     */
    stq_be_p(mb + 0x00, ((uint64_t)0x40 << 48) |
                        ((uint64_t)2 << 32) |
                        ((uint64_t)5000 << 16) | 42);
    mb[0x09] = 0;                             /* PPF id */
    stw_be_p(mb + 0x0a, 3);                   /* command interface rev 3 */
    mb[0x0f] = 5;                             /* log2 max commands = 32 */
    stq_be_p(mb + 0x20, MLX4_CLR_INT_OFFSET); /* clear-interrupt register */
    mb[0x28] = 0;                             /* clear-interrupt BAR = 0 */
    stq_be_p(mb + 0x30, MLX4_CATAS_OFFSET);   /* catastrophic error buffer */
    stl_be_p(mb + 0x38, MLX4_CATAS_SIZE_DWORDS);
    mb[0x3c] = 0;                             /* catas BAR = 0 */
}

static void mlx4_fill_query_dev_cap(Mlx4State *s, uint8_t *mb)
{
    uint32_t flags, ext_flags;

    /*
     * Conservative but self-consistent capability set.  The cap values must
     * survive the sanity checks in mlx4_dev_cap(): min_page_sz <= PAGE_SIZE,
     * num_ports <= 2, uar_size <= BAR2, max ICM size >= the driver profile.
     */
    mb[0x10] = 16;                  /* log max SRQ size */
    mb[0x11] = 16;                  /* log max WQEs per QP */
    mb[0x12] = 4;                   /* log reserved QPs: 16 */
    mb[0x13] = 18;                  /* log max QPs */
    mb[0x14] = 1 << 4;              /* log reserved SRQs: 2 */
    mb[0x15] = 16;                  /* log max SRQs */
    mb[0x19] = 16;                  /* log max CQEs per CQ */
    mb[0x1a] = 1;                   /* log reserved CQs: 2 */
    mb[0x1b] = 16;                  /* log max CQs */
    mb[0x1d] = 19;                  /* log max MPTs */
    mb[0x1e] = 1;                   /* log reserved EQs: 2 */
    mb[0x1f] = 7;                   /* log max EQs: 128 */
    mb[0x20] = 0;                   /* log reserved MTTs: 1 */
    stw_be_p(mb + 0x21, 17);        /* max MRW size */
    mb[0x22] = 2;                   /* log reserved MRWs: 4 */
    mb[0x23] = 13;                  /* max MTT segment size */
    stw_be_p(mb + 0x26, 0);         /* no system EQs (SYS_EQS off) */
    mb[0x29] = 16;                  /* max RDMA requester per QP */
    mb[0x2b] = 16;                  /* max RDMA responder per QP */
    mb[0x2d] = 16;                  /* max GSO size */
    mb[0x2e] = 0;                   /* no RSS table (keeps the model simple) */
    mb[0x2f] = 22;                  /* max RDMA global */
    mb[0x35] = 0;                   /* local ack delay */
    mb[0x37] = s->num_ports;        /* number of ports */
    mb[0x38] = 21;                  /* log max message size */
    mb[0x3b] = 4;                   /* log max GIDs: 16 */
    stw_be_p(mb + 0x3c, 0);         /* stat rate support */
    mb[0x3f] = 4;                   /* log max P_Keys: 16 */

    /*
     * Device capability flags are split into two 32-bit words:
     * 0x40 = bits 63:32 (extended), 0x44 = bits 31:0.
     *   bit 12 DPDP, bit 15 LSO, bit 55 SENSE_SUPPORT.
     */
    flags = (1u << 15) | (1u << 12);
    ext_flags = 1u << (55 - 32);
    stl_be_p(mb + 0x40, ext_flags);
    stl_be_p(mb + 0x44, flags);

    mb[0x48] = 1 << 4;              /* reserved UARs: 1 page */
    mb[0x49] = 3;                   /* UAR area: 2^(3+20) = 8 MiB = BAR2 */
    mb[0x4b] = 12;                  /* min page size: 4 KiB */
    mb[0x4c] = 0;                   /* no blue flame */

    mb[0x51] = 32;                  /* max SQ scatter-gather entries */
    stw_be_p(mb + 0x52, 0x400);     /* max SQ WQE size */
    mb[0x55] = 32;                  /* max RQ scatter-gather entries */
    stw_be_p(mb + 0x56, 0x400);     /* max RQ WQE size */

    mb[0x5c] = 0;                   /* user MAC control not supported */
    mb[0x5d] = 0;                   /* no SVLAN by QP */
    mb[0x61] = 3;                   /* log max QPs per MCG */
    mb[0x62] = 2;                   /* reserved MGMs */
    mb[0x63] = 10;                  /* log max MCGs: 1024 */
    mb[0x64] = 4 << 4;              /* reserved PDs */
    mb[0x65] = 16;                  /* log max PDs */
    mb[0x66] = 0;                   /* no XRC */
    mb[0x67] = 0;
    stl_be_p(mb + 0x68, 0);         /* no counters */

    stl_be_p(mb + 0x70, 0);         /* ext flags 2: no special features */
    mb[0x7a] = 0;                   /* no ETH_PROT_CTRL (PTYS/ACCESS_REG) */

    stw_be_p(mb + 0x80, 16);        /* RDMARC entry size */
    stw_be_p(mb + 0x82, 256);       /* QPC entry size */
    stw_be_p(mb + 0x84, 32);        /* AUXC entry size */
    stw_be_p(mb + 0x86, 64);        /* ALTC entry size */
    stw_be_p(mb + 0x88, 64);        /* EQC entry size */
    stw_be_p(mb + 0x8a, 64);        /* CQC entry size */
    stw_be_p(mb + 0x8c, 32);        /* SRQC entry size */
    stw_be_p(mb + 0x8e, 64);        /* cMPT entry size */
    stw_be_p(mb + 0x90, 8);         /* MTT entry size */
    stw_be_p(mb + 0x92, 64);        /* dMPT entry size */

    stl_be_p(mb + 0x94, 0);         /* BMME flags */
    stl_be_p(mb + 0x98, 0);         /* reserved L_Key */
    stl_be_p(mb + 0x9c, 0);         /* no backplane autoneg reporting */

    /*
     * Context memory size.  It must be >= the profile built by the driver:
     * the cMPT alone is 4 << 24 entries * cmpt_entry_sz = 4 GiB with 64-byte
     * entries, and the field is 64-bit for exactly that reason.
     */
    stq_be_p(mb + 0xa0, 0x200000000ULL);

    s->mtt_entry_sz = 8;
}

static void mlx4_fill_query_port(Mlx4State *s, uint8_t *mb, uint32_t port)
{
    uint64_t mac = (s->def_mac & 0xffffffffffffULL) + (port - 1);

    /* Link up, suggested type Ethernet (bit 3), supported type Ethernet. */
    mb[0x00] = 0x80 | 0x08 | 0x02;
    mb[0x01] = 0x05;                /* IB MTU code (unused for ETH) */
    stw_be_p(mb + 0x02, 9000);      /* Ethernet MTU capability */
    mb[0x05] = 0x02;                /* link speed: 1G */
    mb[0x06] = 0x02;                /* max port width */
    mb[0x07] = 0x44;                /* 16 GIDs / 16 P_Keys */
    mb[0x0a] = 0x77;                /* 128 MACs / 128 VLANs */
    mb[0x0b] = 0x88;                /* max VL / max TC */
    stq_be_p(mb + 0x10, mac);       /* factory MAC address */
    mb[0x18] = 0x00;                /* transceiver: twisted pair */
}

static void mlx4_fill_query_adapter(uint8_t *mb)
{
    mb[0x10] = 1;                   /* INTx pin */
}

static uint8_t mlx4_cmd_exec(Mlx4State *s, uint16_t op, uint8_t opmod,
                             uint32_t in_mod, uint64_t in_param,
                             uint64_t out_param, uint64_t *imm)
{
    uint8_t mb[MLX4_MBOX_SIZE];
    unsigned int i, n;

    switch (op) {
    case CMD_QUERY_FW:
        memset(mb, 0, 0x100);
        mlx4_fill_query_fw(s, mb);
        if (!out_param || !mlx4_dma_write(s, out_param, mb, 0x100)) {
            return CMD_STAT_BAD_PARAM;
        }
        return CMD_STAT_OK;

    case CMD_QUERY_DEV_CAP:
        memset(mb, 0, 0x100);
        mlx4_fill_query_dev_cap(s, mb);
        if (!out_param || !mlx4_dma_write(s, out_param, mb, 0x100)) {
            return CMD_STAT_BAD_PARAM;
        }
        return CMD_STAT_OK;

    case CMD_QUERY_PORT:
        if (in_mod < 1 || in_mod > s->num_ports) {
            mlx4_dbg(s, "QUERY_PORT: bad port %u", in_mod);
            return CMD_STAT_BAD_PARAM;
        }
        memset(mb, 0, 0x100);
        mlx4_fill_query_port(s, mb, in_mod);
        if (s->evil) {
            /*
             * "evil device" mode: out-of-range values in the data the driver
             * is expected to sanitize.  Used by the crash-hunting run.
             */
            stw_be_p(mb + 0x02, 0xffff);
            mb[0x05] = 0x6f;
            mb[0x18] = 0xff;
            stq_be_p(mb + 0x10, 0x02ffffffffffULL);
        }
        if (!out_param || !mlx4_dma_write(s, out_param, mb, 0x100)) {
            return CMD_STAT_BAD_PARAM;
        }
        return CMD_STAT_OK;

    case CMD_QUERY_ADAPTER:
        memset(mb, 0, 0x100);
        mlx4_fill_query_adapter(mb);
        if (!out_param || !mlx4_dma_write(s, out_param, mb, 0x100)) {
            return CMD_STAT_BAD_PARAM;
        }
        return CMD_STAT_OK;

    case CMD_SET_ICM_SIZE:
        /* Number of 4 KiB auxiliary ICM pages the firmware asks for. */
        *imm = 64;
        return CMD_STAT_OK;

    case CMD_MAP_ICM:
        n = in_mod & 0x1ff;
        if (n > MLX4_MBOX_SIZE / 16) {
            n = MLX4_MBOX_SIZE / 16;
        }
        if (!n) {
            return CMD_STAT_OK;
        }
        if (!in_param || !mlx4_dma_read(s, in_param, mb, n * 16)) {
            return CMD_STAT_BAD_PARAM;
        }
        for (i = 0; i < n; i++) {
            uint64_t va = ldq_be_p(mb + i * 16);
            uint64_t desc = ldq_be_p(mb + i * 16 + 8);
            unsigned int lg = 12 + (desc & 0x3f);
            uint64_t pa = desc & ~0x3fULL;

            mlx4_icm_add(s, va, pa, 1ULL << lg);
        }
        return CMD_STAT_OK;

    case CMD_INIT_HCA:
        memset(mb, 0, 0x200);
        if (!in_param || !mlx4_dma_read(s, in_param, mb, 0x200)) {
            return CMD_STAT_BAD_PARAM;
        }
        /*
         * The MTT address stored in EQ/CQ/QP contexts is relative to the MTT
         * table, whose base is passed in INIT_HCA.  Remember it: it is needed
         * to locate the async EQ ring in host memory.
         */
        s->mtt_base = ldq_be_p(mb + 0x100);
        mlx4_dbg(s, "INIT_HCA mtt_base=%#" PRIx64, s->mtt_base);
        return CMD_STAT_OK;

    case CMD_MAP_FA:
    case CMD_UNMAP_FA:
    case CMD_RUN_FW:
    case CMD_MAP_ICM_AUX:
    case CMD_UNMAP_ICM_AUX:
    case CMD_UNMAP_ICM:
    case CMD_MOD_STAT_CFG:
    case CMD_CLOSE_HCA:
    case CMD_QUERY_FUNC:
        return CMD_STAT_OK;

    case CMD_MAP_EQ:
        if (!(in_mod & (1u << 31)) && (in_param & (1ULL << MLX4_EVENT_TYPE_CMD))) {
            s->async_eqn = in_mod & 0x3ff;
            mlx4_dbg(s, "async EQ is eqn %d", s->async_eqn);
        }
        return CMD_STAT_OK;

    case CMD_SW2HW_EQ: {
        uint32_t eqn = in_mod & 0x3ff;

        if (eqn >= MLX4_MAX_EQ) {
            return CMD_STAT_BAD_PARAM;
        }
        memset(mb, 0, 64);
        if (!in_param || !mlx4_dma_read(s, in_param, mb, 64)) {
            return CMD_STAT_BAD_PARAM;
        }
        s->eqs[eqn].valid = true;
        s->eqs[eqn].log_eq_size = mb[12];
        s->eqs[eqn].intr = mb[23];
        s->eqs[eqn].mtt_addr = ((uint64_t)mb[27] << 32) |
                               (uint64_t)ldl_be_p(mb + 28);
        s->eqs[eqn].prod = 0;
        mlx4_dbg(s, "SW2HW_EQ eqn=%u log_size=%u intr=%u mtt=%#" PRIx64,
                 eqn, s->eqs[eqn].log_eq_size, s->eqs[eqn].intr,
                 s->eqs[eqn].mtt_addr);
        mlx4_eq_ring_init(s, eqn);
        return CMD_STAT_OK;
    }

    case CMD_HW2SW_EQ:
        if ((in_mod & 0x3ff) < MLX4_MAX_EQ) {
            s->eqs[in_mod & 0x3ff].valid = false;
        }
        return CMD_STAT_OK;

    case CMD_SW2HW_CQ:
    case CMD_HW2SW_CQ:
    case CMD_MODIFY_CQ:
    case CMD_SW2HW_SRQ:
    case CMD_HW2SW_SRQ:
    case CMD_ARM_SRQ:
    case CMD_SW2HW_MPT:
    case CMD_HW2SW_MPT:
    case CMD_WRITE_MTT:
    case CMD_SYNC_TPT:
    case CMD_RST2INIT_QP:
    case CMD_INIT2RTR_QP:
    case CMD_RTR2RTS_QP:
    case CMD_RTS2RTS_QP:
    case CMD_SQERR2RTS_QP:
    case CMD_2ERR_QP:
    case CMD_RTS2SQD_QP:
    case CMD_SQD2SQD_QP:
    case CMD_SQD2RTS_QP:
    case CMD_2RST_QP:
    case CMD_CONF_SPECIAL_QP:
    case CMD_WRITE_MCG:
    case CMD_SET_PORT:
    case CMD_INIT_PORT:
    case CMD_CLOSE_PORT:
    case CMD_SET_VLAN_FLTR:
    case CMD_SET_MCAST_FLTR:
    case CMD_ACCESS_REG:
    case CMD_NOP:
    case CMD_HW_HEALTH_CHECK:
        return CMD_STAT_OK;

    case CMD_MGID_HASH:
        *imm = 0;
        return CMD_STAT_OK;

    case CMD_SENSE_PORT:
        *imm = 2;                   /* Ethernet */
        return CMD_STAT_OK;

    case CMD_QUERY_QP:
    case CMD_QUERY_CQ:
    case CMD_QUERY_SRQ:
    case CMD_QUERY_MPT:
    case CMD_QUERY_EQ:
    case CMD_READ_MCG:
    case CMD_READ_MTT:
    case CMD_MAD_IFC:
        memset(mb, 0, 0x100);
        if (out_param) {
            mlx4_dma_write(s, out_param, mb, 0x100);
        }
        return CMD_STAT_OK;

    case CMD_DUMP_ETH_STATS:
        memset(mb, 0, sizeof(mb));
        if (out_param) {
            mlx4_dma_write(s, out_param, mb, sizeof(mb));
        }
        return CMD_STAT_OK;

    default:
        /*
         * Unknown opcodes are completed successfully: the goal is to let the
         * driver load and expose its administrative surface.  The command is
         * logged so that missing pieces can be added while iterating.
         */
        mlx4_dbg(s, "unhandled command op=%#x op_mod=%#x in_mod=%#x",
                 op, opmod, in_mod);
        return CMD_STAT_OK;
    }
}

/* ------------------------------------------------------------------ */
/* BAR0                                                                */
/* ------------------------------------------------------------------ */

static void mlx4_reset(Mlx4State *s)
{
    memset(s->hcr, 0, sizeof(s->hcr));
    memset(s->eqs, 0, sizeof(s->eqs));
    s->async_eqn = -1;
    s->mtt_base = 0;
    mlx4_icm_reset(s);
    if (s->irq_asserted) {
        s->irq_asserted = false;
        pci_irq_deassert(PCI_DEVICE(s));
    }
    mlx4_dbg(s, "device reset");
}

static void mlx4_hcr_write(Mlx4State *s, unsigned int reg, uint32_t value)
{
    uint8_t status;
    uint16_t op;
    uint8_t opmod;
    uint16_t token;
    uint64_t in_param, out_param, imm = 0;
    bool event;

    if (reg != HCR_CTRL) {
        s->hcr[reg] = value;
        return;
    }

    if (!(value & (1u << HCR_GO_BIT))) {
        s->hcr[HCR_CTRL] = value;
        return;
    }

    op = value & 0xfff;
    opmod = (value >> 12) & 0xff;
    event = value & (1u << HCR_E_BIT);
    token = s->hcr[HCR_TOKEN] >> 16;
    in_param = ((uint64_t)s->hcr[HCR_IN_HI] << 32) | s->hcr[HCR_IN_LO];
    out_param = ((uint64_t)s->hcr[HCR_OUT_HI] << 32) | s->hcr[HCR_OUT_LO];

    status = mlx4_cmd_exec(s, op, opmod, s->hcr[HCR_IN_MOD], in_param,
                           out_param, &imm);

    /* Immediate output is visible both in the HCR and in the EQE. */
    s->hcr[HCR_OUT_HI] = (uint32_t)(imm >> 32);
    s->hcr[HCR_OUT_LO] = (uint32_t)imm;

    /* Complete the command: clear GO, keep T/E/opcode bits, set status. */
    s->hcr[HCR_CTRL] = (value & ~(1u << HCR_GO_BIT)) | ((uint32_t)status << 24);

    mlx4_dbg(s, "cmd op=%#x op_mod=%#x in_mod=%#x token=%#x event=%d -> %#x",
             op, opmod, s->hcr[HCR_IN_MOD], token, event, status);

    if (event) {
        mlx4_eqe_post_cmd(s, token, status, imm);
    }
}

static uint64_t mlx4_bar0_read(void *opaque, hwaddr addr, unsigned int size)
{
    Mlx4State *s = MLX4_DEVICE(opaque);
    uint64_t data = 0;

    if (size != 4) {
        return 0;
    }

    if (addr >= MLX4_HCR_OFFSET &&
        addr < MLX4_HCR_OFFSET + MLX4_HCR_DWORDS * 4) {
        return s->hcr[(addr - MLX4_HCR_OFFSET) / 4];
    }
    if (addr == MLX4_OWNER_OFFSET) {
        /*
         * Reading the ownership semaphore has a side effect: the first
         * reader becomes the owner and sees 0, everybody else sees 1.
         */
        if (!s->owned) {
            s->owned = true;
            mlx4_dbg(s, "ownership acquired");
        } else {
            data = 1;
        }
        return data;
    }
    if (addr == MLX4_RESET_SEM_OFFSET) {
        return 0;
    }
    /* Catastrophic error buffer and unknown registers read as zero. */
    return 0;
}

static void mlx4_bar0_write(void *opaque, hwaddr addr, uint64_t data,
                            unsigned int size)
{
    Mlx4State *s = MLX4_DEVICE(opaque);

    if (size != 4) {
        return;
    }

    if (addr >= MLX4_HCR_OFFSET &&
        addr < MLX4_HCR_OFFSET + MLX4_HCR_DWORDS * 4) {
        mlx4_hcr_write(s, (addr - MLX4_HCR_OFFSET) / 4, (uint32_t)data);
        return;
    }
    if (addr == MLX4_OWNER_OFFSET) {
        if (data == 0) {
            s->owned = false;
            mlx4_dbg(s, "ownership released");
        }
        return;
    }
    if (addr == MLX4_RESET_REG_OFFSET) {
        if (data == 1) {
            mlx4_reset(s);
        }
        return;
    }
    if (addr >= MLX4_CLR_INT_OFFSET && addr < MLX4_CLR_INT_OFFSET + 8) {
        /* The driver acknowledges a legacy interrupt through this register. */
        mlx4_dbg(s, "CLR_INT write %#" PRIx64 " at %#" HWADDR_PRIx, data, addr);
        if (s->irq_asserted) {
            s->irq_asserted = false;
            pci_irq_deassert(PCI_DEVICE(s));
        }
        return;
    }
}

static const MemoryRegionOps mlx4_bar0_ops = {
    .read = mlx4_bar0_read,
    .write = mlx4_bar0_write,
    .endianness = DEVICE_BIG_ENDIAN,
    .valid = {
        .min_access_size = 4,
        .max_access_size = 4,
    },
    .impl = {
        .min_access_size = 4,
        .max_access_size = 4,
    },
};

/* BAR2 is the UAR area: doorbells are accepted and ignored. */
static uint64_t mlx4_bar2_read(void *opaque, hwaddr addr, unsigned int size)
{
    return 0;
}

static void mlx4_bar2_write(void *opaque, hwaddr addr, uint64_t data,
                            unsigned int size)
{
    Mlx4State *s = MLX4_DEVICE(opaque);

    mlx4_dbg(s, "UAR write addr=%#" HWADDR_PRIx " data=%#" PRIx64 " size=%u",
             addr, data, size);
}

static const MemoryRegionOps mlx4_bar2_ops = {
    .read = mlx4_bar2_read,
    .write = mlx4_bar2_write,
    .endianness = DEVICE_BIG_ENDIAN,
    .valid = {
        .min_access_size = 4,
        .max_access_size = 8,
    },
    .impl = {
        .min_access_size = 4,
        .max_access_size = 8,
    },
};

/* ------------------------------------------------------------------ */
/* QOM plumbing                                                        */
/* ------------------------------------------------------------------ */

static void mlx4_realize(PCIDevice *pci, Error **errp)
{
    Mlx4State *s = MLX4_DEVICE(pci);

    memory_region_init_io(&s->bar0, OBJECT(s), &mlx4_bar0_ops, s,
                          "mlx4-bar0", MLX4_BAR0_SIZE);
    pci_register_bar(pci, 0,
                     PCI_BASE_ADDRESS_SPACE_MEMORY |
                     PCI_BASE_ADDRESS_MEM_TYPE_64,
                     &s->bar0);

    memory_region_init_io(&s->bar2, OBJECT(s), &mlx4_bar2_ops, s,
                          "mlx4-bar2", MLX4_BAR2_SIZE);
    pci_register_bar(pci, 2,
                     PCI_BASE_ADDRESS_SPACE_MEMORY |
                     PCI_BASE_ADDRESS_MEM_TYPE_64,
                     &s->bar2);

    pci_config_set_interrupt_pin(pci->config, 1);

    /*
     * MSI-X is optional.  The Linux driver works fine with legacy INTx, and
     * INTx avoids the driver's 60-second NOP/MSI-X probe before the fallback,
     * so INTx is the default.  Use msix=on to exercise the MSI-X path.
     */
    if (s->msix &&
        msix_init(pci, MLX4_MSIX_VECTORS, &s->bar0, 0, MLX4_MSIX_TABLE_OFFSET,
                  &s->bar0, 0, MLX4_MSIX_PBA_OFFSET, 0, NULL) == 0) {
        s->msix_ok = true;
    } else {
        s->msix_ok = false;
    }

    s->async_eqn = -1;
    s->mtt_entry_sz = 8;
    if (!s->num_ports) {
        s->num_ports = 2;
    }
    if (s->num_ports > 2) {
        s->num_ports = 2;
    }
    if (!s->def_mac) {
        s->def_mac = 0x525400dead01ULL;
    }

    mlx4_dbg(s, "realized: ports=%u mac=%012" PRIx64 " msix=%d",
             s->num_ports, s->def_mac, s->msix_ok);
}

static void mlx4_exit(PCIDevice *pci)
{
    Mlx4State *s = MLX4_DEVICE(pci);

    if (s->msix_ok) {
        msix_uninit(pci, &s->bar0, &s->bar0);
    }
}

static void mlx4_instance_init(Object *obj)
{
    Mlx4State *s = MLX4_DEVICE(obj);

    s->async_eqn = -1;
}

static const Property mlx4_properties[] = {
    DEFINE_PROP_UINT32("ports", Mlx4State, num_ports, 2),
    DEFINE_PROP_UINT64("mac", Mlx4State, def_mac, 0x525400dead01ULL),
    DEFINE_PROP_BOOL("verbose", Mlx4State, verbose, false),
    DEFINE_PROP_BOOL("evil", Mlx4State, evil, false),
    DEFINE_PROP_BOOL("msix", Mlx4State, msix, false),
};

static void mlx4_class_init(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *k = PCI_DEVICE_CLASS(klass);

    k->realize = mlx4_realize;
    k->exit = mlx4_exit;
    k->vendor_id = MLX4_PCI_VENDOR_ID;
    k->device_id = MLX4_PCI_DEVICE_ID_CX3;
    k->revision = 0;
    k->class_id = PCI_CLASS_NETWORK_ETHERNET;

    device_class_set_props(dc, mlx4_properties);
    dc->desc = "Mellanox ConnectX-3 (mlx4) emulation";
    set_bit(DEVICE_CATEGORY_NETWORK, dc->categories);
}

static const TypeInfo mlx4_info = {
    .name = TYPE_MLX4_DEVICE,
    .parent = TYPE_PCI_DEVICE,
    .instance_size = sizeof(Mlx4State),
    .instance_init = mlx4_instance_init,
    .class_init = mlx4_class_init,
    .interfaces = (const InterfaceInfo[]) {
        { INTERFACE_CONVENTIONAL_PCI_DEVICE },
        { },
    },
};

static void mlx4_register_types(void)
{
    type_register_static(&mlx4_info);
}

type_init(mlx4_register_types)
