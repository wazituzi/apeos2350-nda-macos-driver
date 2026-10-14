/*
 * rastertohbpl - CUPS filter for the FUJIFILM Apeos 2350 NDA.
 *
 * The Apeos 2150 N / 2350 NDA family has no page description language of its
 * own: it is a host-based ("HBPL", Host Based Print Language) device, so the
 * host must render and halftone every page.  FUJIFILM only ships a Windows
 * driver, which is why the machine cannot be used from macOS out of the box.
 *
 * This filter closes that gap with nothing but components that already exist
 * on the Mac:
 *
 *     PDF -> cgpdftoraster (Apple, built in) -> CUPS raster
 *         -> [ this filter: raster -> pbmraw -> HBPL ] -> socket://...:9100
 *
 * The raster parsing and the HBPL encoder are both in this single binary, so
 * the CUPS filter sandbox never has to launch a helper process.
 *
 * The HBPL encoder is foo2hbpl2 by Rick Richardson (GPLv2), whose HBPL v2
 * output was verified to print correctly on this exact printer model.
 *
 * Build:
 *   cc -O2 -o rastertohbpl rastertohbpl.c foo2hbpl2_enc.o jbig.o jbig_ar.o
 * (foo2hbpl2.c is compiled separately with -Dmain=foo2hbpl2_main)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>

/* ------------------------------------------------------------------ raster */

#define RASTER_SYNC   0x52615333u   /* "RaSt" */
#define RASTER_SYNCv1 0x52615374u   /* "Rast" */
#define RASTER_SYNCv2 0x52615332u   /* "RaS2" */
#define RASTER_REVSYNC 0x33536152u

#define HEADER2_SIZE 1796u          /* sizeof(cups_page_header2_t) */
#define HEADER1_SIZE 1780u          /* sizeof(cups_page_header_t)  */

/* Field offsets inside cups_page_header*.  Verified against real
 * cgpdftoraster output on macOS 27 (sync + 1796-byte header + bitmap). */
#define OFF_DUPLEX       272u
#define OFF_TUMBLE       368u
#define OFF_NUMCOPIES    340u
#define OFF_COLLATE      264u
#define OFF_PAGESIZE     352u       /* unsigned[2], points */
#define OFF_CUPSWIDTH    372u
#define OFF_CUPSHEIGHT   376u
#define OFF_BITSPERCOLOR 384u
#define OFF_BITSPERPIXEL 388u
#define OFF_BYTESPERLINE 392u
#define OFF_COLORSPACE   400u

/* CUPS colour spaces we care about */
#define CSPACE_W   0u
#define CSPACE_K   3u
#define CSPACE_SW  18u

/* foo2hbpl2 paper codes (see foo2hbpl2-wrapper): 1=A4 2=B5 3=A5 4=Letter
 * 5=Executive 6=Folio 7=Legal.  Pick by page size in points. */
struct paper { unsigned w, h; int code; };
static const struct paper PAPERS[] = {
    { 595,  842, 1},    /* A4        */
    { 516,  729, 2},    /* B5 (JIS)  */
    { 420,  595, 3},    /* A5        */
    { 612,  792, 4},    /* Letter    */
    { 522,  756, 5},    /* Executive */
    { 612,  936, 6},    /* Folio     */
    { 612, 1008, 7},    /* Legal     */
};

static unsigned get_u32(const unsigned char *h, size_t off)
{
    return (unsigned)h[off] | ((unsigned)h[off + 1] << 8) |
           ((unsigned)h[off + 2] << 16) | ((unsigned)h[off + 3] << 24);
}

/* 8x8 Bayer matrix, values 0..63 */
static const int BAYER[8][8] = {
    { 0, 32,  8, 40,  2, 34, 10, 42},
    {48, 16, 56, 24, 50, 18, 58, 26},
    {12, 44,  4, 36, 14, 46,  6, 38},
    {60, 28, 52, 20, 62, 30, 54, 22},
    { 3, 35, 11, 43,  1, 33,  9, 41},
    {51, 19, 59, 27, 49, 17, 57, 25},
    {15, 47,  7, 39, 13, 45,  5, 37},
    {63, 31, 55, 23, 61, 29, 53, 21},
};

/*
 * Convert one CUPS raster page into a PBM P4 image appended to `out`.
 * Returns 0 on success.
 */
static int page_to_pbm(FILE *in, FILE *out, const unsigned char *hdr,
                       unsigned *pw, unsigned *ph, unsigned *pap)
{
    unsigned width  = get_u32(hdr, OFF_CUPSWIDTH);
    unsigned height = get_u32(hdr, OFF_CUPSHEIGHT);
    unsigned bpp    = get_u32(hdr, OFF_BITSPERPIXEL);
    unsigned bpc    = get_u32(hdr, OFF_BITSPERCOLOR);
    unsigned bpl    = get_u32(hdr, OFF_BYTESPERLINE);
    unsigned cs     = get_u32(hdr, OFF_COLORSPACE);
    unsigned psz[2];
    unsigned row, x;
    unsigned char *rowbuf;
    unsigned char *pbmrow;
    int black_is_high;          /* true => larger sample value is blacker */

    psz[0] = get_u32(hdr, OFF_PAGESIZE);
    psz[1] = get_u32(hdr, OFF_PAGESIZE + 4);

    if (!width || !height || !bpl || !bpp) {
        fprintf(stderr, "ERROR: bad CUPS raster header (%ux%u bpp=%u bpl=%u)\n",
                width, height, bpp, bpl);
        return -1;
    }
    if (bpl > 1u << 20) {
        fprintf(stderr, "ERROR: implausible bytes-per-line %u\n", bpl);
        return -1;
    }

    /* K (black) counts up towards black; W/SW count up towards white. */
    black_is_high = (cs == CSPACE_K);

    rowbuf = malloc(bpl);
    pbmrow = malloc((width + 7) / 8);
    if (!rowbuf || !pbmrow) {
        fprintf(stderr, "ERROR: out of memory\n");
        free(rowbuf); free(pbmrow);
        return -1;
    }

    fprintf(out, "P4\n%u %u\n", width, height);

    for (row = 0; row < height; row++) {
        size_t n = fread(rowbuf, 1, bpl, in);
        if (n < bpl) {
            fprintf(stderr, "ERROR: short read on page data "
                            "(row %u of %u, got %zu of %u)\n",
                    row, height, n, bpl);
            free(rowbuf); free(pbmrow);
            return -1;
        }
        memset(pbmrow, 0, (width + 7) / 8);

        if (bpp == 1) {
            /* Already halftoned; PBM and CUPS both use 1 = black. */
            for (x = 0; x < width; x++) {
                unsigned byte = rowbuf[x >> 3];
                int bit = (byte >> (7 - (x & 7))) & 1;
                if (!black_is_high)
                    bit = !bit;
                if (bit)
                    pbmrow[x >> 3] |= 0x80u >> (x & 7);
            }
        } else if (bpp == 8) {
            for (x = 0; x < width; x++) {
                unsigned v = rowbuf[x];
                int threshold = black_is_high
                    ? (BAYER[row & 7][x & 7] * 255) / 63
                    : 255 - (BAYER[row & 7][x & 7] * 255) / 63;
                int bit = black_is_high ? (int)v > threshold
                                        : (int)v < threshold;
                if (bit)
                    pbmrow[x >> 3] |= 0x80u >> (x & 7);
            }
        } else {
            fprintf(stderr, "ERROR: unsupported %u bits/pixel (%u per colour)\n",
                    bpp, bpc);
            free(rowbuf); free(pbmrow);
            return -1;
        }
        if (fwrite(pbmrow, 1, (width + 7) / 8, out) != (width + 7) / 8) {
            fprintf(stderr, "ERROR: write failed\n");
            free(rowbuf); free(pbmrow);
            return -1;
        }
    }

    free(rowbuf);
    free(pbmrow);

    if (pw) *pw = width;
    if (ph) *ph = height;
    if (pap) {
        int code = 1;               /* default A4 */
        size_t i;
        for (i = 0; i < sizeof(PAPERS) / sizeof(PAPERS[0]); i++) {
            if (psz[0] >= PAPERS[i].w - 3 && psz[0] <= PAPERS[i].w + 3 &&
                psz[1] >= PAPERS[i].h - 3 && psz[1] <= PAPERS[i].h + 3) {
                code = PAPERS[i].code;
                break;
            }
        }
        *pap = (unsigned)code;
    }
    return 0;
}

/* -------------------------------------------------------------------- main */

/* Copy `in` from the beginning to `out`. */
static int copy_stream(FILE *in, FILE *out)
{
    unsigned char buf[65536];
    size_t n;

    rewind(in);
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0)
        if (fwrite(buf, 1, n, out) != n)
            return -1;
    return 0;
}

/* Append one all-white PBM page.  In PBM 1 means black, so zeros are white. */
static int write_blank_page(FILE *out, unsigned w, unsigned h)
{
    unsigned char zero[4096];
    size_t rowbytes = (w + 7u) / 8u;
    unsigned y;

    memset(zero, 0, sizeof(zero));
    fprintf(out, "P4\n%u %u\n", w, h);
    for (y = 0; y < h; y++) {
        size_t left = rowbytes;
        while (left > 0) {
            size_t chunk = left < sizeof(zero) ? left : sizeof(zero);
            if (fwrite(zero, 1, chunk, out) != chunk)
                return -1;
            left -= chunk;
        }
    }
    return 0;
}

extern int foo2hbpl2_main(int argc, char **argv);

int main(int argc, char **argv)
{
    const char *jobid = argc > 1 ? argv[1] : "1";
    const char *user  = argc > 2 ? argv[2] : "";
    const char *title = argc > 3 ? argv[3] : "Untitled";
    const char *copies_s = argc > 4 ? argv[4] : "1";
    const char *file  = argc > 6 ? argv[6] : NULL;
    FILE *in, *tmp;
    unsigned char syncd[4];
    uint32_t sync;
    unsigned char hdr[HEADER2_SIZE];
    unsigned page = 0, width = 0, height = 0, paper = 1;
    unsigned copies = (unsigned)atoi(copies_s);
    unsigned duplex = 0, tumble = 0, collate = 0;
    unsigned printer_copies = 1;
    char dim[64];
    char copyopt[32];
    char pjlname[256];
    char pjluser[128];
    char *child_argv[16];
    int child_argc = 0;
    int rc;

    /* Keep our own stream for the raster so that stdin stays untouched: we
     * hand stdin to the HBPL encoder later. */
    if (file) {
        in = fopen(file, "rb");
        if (!in) { perror(file); return 1; }
    } else {
        in = fdopen(dup(STDIN_FILENO), "rb");
        if (!in) { perror("stdin"); return 1; }
    }

    tmp = tmpfile();
    if (!tmp) { perror("tmpfile"); return 1; }

    for (;;) {
        unsigned hsize = HEADER2_SIZE;
        size_t got = fread(syncd, 1, 4, in);

        if (got < 4)
            break;                              /* clean end of stream */

        memcpy(&sync, syncd, 4);

        if (sync == RASTER_SYNC || sync == RASTER_SYNCv1 ||
            sync == RASTER_SYNCv2) {
            if (sync == RASTER_SYNCv1)
                hsize = HEADER1_SIZE;
            if (fread(hdr, 1, hsize, in) != hsize) {
                fprintf(stderr, "ERROR: short page header on page %u\n",
                        page + 1);
                fclose(in); fclose(tmp);
                return 1;
            }
        } else if (page == 0) {
            fprintf(stderr, "ERROR: stream does not start with a CUPS raster "
                            "sync word (got 0x%08x)\n", sync);
            fclose(in); fclose(tmp);
            return 1;
        } else {
            /*
             * macOS' cgpdftoraster emits the sync word only once per stream
             * and then writes a bare page header for every following page
             * (verified byte-for-byte: 4+1796+data, then 1796+data, with the
             * file size matching exactly).  So these four bytes are already
             * the first four bytes of the header.
             */
            memcpy(hdr, syncd, 4);
            if (fread(hdr + 4, 1, HEADER2_SIZE - 4, in) != HEADER2_SIZE - 4) {
                fprintf(stderr, "ERROR: short page header on page %u\n",
                        page + 1);
                fclose(in); fclose(tmp);
                return 1;
            }
        }

        if (page == 0) {
            /* CUPS raster carries two independent flags: Duplex is on/off and
             * Tumble selects the back-side binding (0 = long edge /
             * no-tumble, 1 = short edge / tumble).  Reading only Duplex made
             * both duplex modes come out as long edge. */
            duplex = get_u32(hdr, OFF_DUPLEX);
            tumble = get_u32(hdr, OFF_TUMBLE);
            collate = get_u32(hdr, OFF_COLLATE);
            if (!copies)
                copies = get_u32(hdr, OFF_NUMCOPIES);
            if (!copies)
                copies = 1;
        }

        {
            unsigned pw = 0, ph = 0, pp = paper;
            if (page_to_pbm(in, tmp, hdr, &pw, &ph, &pp) != 0) {
                fclose(in); fclose(tmp);
                return 1;
            }
            if (page == 0) {
                width = pw; height = ph; paper = pp;
            } else if (pw != width || ph != height) {
                fprintf(stderr, "WARNING: page %u is %ux%u but page 1 is "
                                "%ux%u; the device is driven with one page "
                                "geometry per job\n",
                        page + 1, pw, ph, width, height);
            }
        }
        page++;
    }
    if (!page) {
        fprintf(stderr, "ERROR: no pages in CUPS raster stream\n");
        fclose(in); fclose(tmp);
        return 1;
    }
    fclose(in);

    /*
     * Collation.
     *
     * "@PJL SET COPIES=n" makes the printer duplicate every page in place, so
     * a two page document with n=2 comes out 1,1,2,2.  That is what an
     * uncollated job should look like, but a collated one has to be 1,2,1,2,
     * and this printer cannot collate by itself.  So a collated job is built
     * here by repeating the whole page sequence in the data stream and
     * telling the printer COPIES=1.
     */
    if (collate && copies > 1) {
        FILE *rep = tmpfile();
        unsigned c;

        if (!rep) {
            perror("tmpfile");
            fclose(tmp);
            return 1;
        }
        for (c = 0; c < copies; c++) {
            if (copy_stream(tmp, rep) != 0) {
                fprintf(stderr, "ERROR: could not repeat the page sequence\n");
                fclose(rep); fclose(tmp);
                return 1;
            }
            /*
             * With duplex the printer pairs consecutive pages onto the two
             * sides of one sheet, so every copy needs an even page count or
             * the copies would be paired across each other.  An explicit
             * blank page makes the tail of an odd document visible, which is
             * the same sheet the printer would emit anyway.
             */
            if (duplex && (page % 2) == 1 &&
                write_blank_page(rep, width, height) != 0) {
                fprintf(stderr, "ERROR: could not pad the page sequence\n");
                fclose(rep); fclose(tmp);
                return 1;
            }
        }
        fclose(tmp);
        tmp = rep;
        printer_copies = 1;
    } else {
        printer_copies = copies;
    }

    /* Hand the PBM to the HBPL encoder on stdin. */
    rewind(tmp);
    if (dup2(fileno(tmp), STDIN_FILENO) < 0) {
        perror("dup2");
        fclose(tmp);
        return 1;
    }

    snprintf(dim, sizeof(dim), "%ux%u", width, height);
    snprintf(copyopt, sizeof(copyopt), "%u", printer_copies);
    snprintf(pjlname, sizeof(pjlname), "%.200s", title);
    snprintf(pjluser, sizeof(pjluser), "%.100s", user);

    child_argv[child_argc++] = (char *)"foo2hbpl2";
    child_argv[child_argc++] = (char *)"-r600x600";
    child_argv[child_argc++] = (char *)"-g"; child_argv[child_argc++] = dim;
    child_argv[child_argc++] = (char *)"-p"; {
        char *pc = malloc(8);
        snprintf(pc, 8, "%u", paper);
        child_argv[child_argc++] = pc;
    }
    child_argv[child_argc++] = (char *)"-n"; child_argv[child_argc++] = copyopt;
    child_argv[child_argc++] = (char *)"-d"; {
        char *dc = malloc(8);
        /* foo2hbpl2: 1=off 2=long edge 3=short edge */
        snprintf(dc, 8, "%u", !duplex ? 1u : (tumble ? 3u : 2u));
        child_argv[child_argc++] = dc;
    }
    child_argv[child_argc++] = (char *)"-J"; child_argv[child_argc++] = pjlname;
    child_argv[child_argc++] = (char *)"-U"; child_argv[child_argc++] = pjluser;
    child_argv[child_argc] = NULL;

    fprintf(stderr, "DEBUG: rastertohbpl: job %s, %u page(s), %ux%u, "
                    "600x600, paper=%u, copies=%u, collate=%u -> "
                    "printer-copies=%u, duplex=%u, tumble=%u\n",
            jobid, page, width, height, paper, copies, collate,
            printer_copies, duplex, tumble);

    rc = foo2hbpl2_main(child_argc, child_argv);

    fclose(tmp);
    return rc;
}
