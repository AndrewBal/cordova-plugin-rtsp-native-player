package com.andrewbal.rtspnativeplayer;

import android.util.Log;

import java.io.ByteArrayOutputStream;

/**
 * RtpDepacketizer — Java port of the iOS RtpParser.
 *
 * Parses RTP packets (RFC 3550) carrying H.264 (RFC 6184) or H.265 (RFC 7798)
 * NAL units and reassembles complete NAL units, handling:
 *   H.264 — single NAL (1-23), STAP-A (24), FU-A (28)
 *   H.265 — single NAL (≤47), AP (48), FU (49)
 *
 * Emitted NAL units do NOT carry an Annex-B start code; the decoder prepends one.
 */
public class RtpDepacketizer {

    private static final String TAG = "RtpDepacketizer";

    public interface Listener {
        /** type = NAL unit type (H.264 5-bit, or H.265 6-bit). timestamp = RTP 90 kHz. */
        void onNalUnit(byte[] nal, int type, long timestamp);
    }

    private final Listener listener;
    private boolean isH265 = false;

    // FU reassembly
    private final ByteArrayOutputStream fuBuffer = new ByteArrayOutputStream(65536);
    private long fuTimestamp;
    private boolean fuInProgress = false;

    private long packetsReceived = 0;

    public RtpDepacketizer(Listener listener) {
        this.listener = listener;
    }

    public void setH265(boolean h265) {
        this.isH265 = h265;
    }

    public void reset() {
        fuBuffer.reset();
        fuInProgress = false;
        packetsReceived = 0;
    }

    public void feed(byte[] rtp) {
        packetsReceived++;
        if (rtp.length < 12) return;

        int csrcCount = rtp[0] & 0x0F;
        long timestamp = ((long) (rtp[4] & 0xFF) << 24) | ((rtp[5] & 0xFF) << 16)
                | ((rtp[6] & 0xFF) << 8) | (rtp[7] & 0xFF);

        int headerLen = 12 + csrcCount * 4;
        boolean extension = ((rtp[0] >> 4) & 0x01) != 0;
        if (extension) {
            if (rtp.length < headerLen + 4) return;
            int extLen = ((rtp[headerLen + 2] & 0xFF) << 8) | (rtp[headerLen + 3] & 0xFF);
            headerLen += 4 + extLen * 4;
        }
        if (rtp.length <= headerLen) return;

        int payloadLen = rtp.length - headerLen;
        if (isH265) {
            dispatchH265(rtp, headerLen, payloadLen, timestamp);
        } else {
            dispatchH264(rtp, headerLen, payloadLen, timestamp);
        }
    }

    // ────────────────────────────────────────────────
    //  H.264
    // ────────────────────────────────────────────────

    private void dispatchH264(byte[] p, int off, int len, long ts) {
        int nalType = p[off] & 0x1F;
        if (nalType >= 1 && nalType <= 23) {
            emitH264MaybeAggregated(p, off, len, ts);
        } else if (nalType == 24) {
            parseStapA(p, off, len, ts);
        } else if (nalType == 28) {
            parseFuA(p, off, len, ts);
        }
    }

    // Some cameras (e.g. lombotech/EEASYTECH) pack a whole access unit
    // (SPS + PPS + IDR) into ONE RTP packet as an Annex-B byte stream with internal
    // start codes, instead of one NAL per packet (RFC 6184). If we emitted that as a
    // single NAL it would be mislabeled by its first byte (SPS), and the IDR would
    // never reach the decoder — only P-frames would, painting over a black frame.
    // Split on start codes (00 00 01 / 00 00 00 01). Emulation prevention guarantees
    // these never occur inside a NAL's RBSP, so the split is unambiguous; a normal
    // single-NAL packet (no internal start codes) is emitted unchanged.
    private void emitH264MaybeAggregated(byte[] p, int off, int len, long ts) {
        int end = off + len;
        int i = off;
        int lead = startCodeLen(p, i, end);
        if (lead > 0) i += lead;          // skip a leading start code if present
        int nalStart = i;
        while (i < end) {
            int scl = startCodeLen(p, i, end);
            if (scl > 0) {
                if (i > nalStart) emitH264Nal(p, nalStart, i - nalStart, ts);
                i += scl;
                nalStart = i;
            } else {
                i++;
            }
        }
        if (end > nalStart) emitH264Nal(p, nalStart, end - nalStart, ts);
    }

    private void emitH264Nal(byte[] p, int off, int len, long ts) {
        if (len <= 0) return;
        emit(copy(p, off, len), p[off] & 0x1F, ts);
    }

    /** Length (3 or 4) of an Annex-B start code at position i, or 0 if none. */
    private int startCodeLen(byte[] p, int i, int end) {
        if (i + 3 < end && p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 0 && p[i + 3] == 1) return 4;
        if (i + 2 < end && p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1) return 3;
        return 0;
    }

    // STAP-A (RFC 6184 §5.7.1): header byte, then [size16 | NAL]+
    private void parseStapA(byte[] p, int off, int len, long ts) {
        int o = off + 1;
        int end = off + len;
        while (o + 2 <= end) {
            int nalSize = ((p[o] & 0xFF) << 8) | (p[o + 1] & 0xFF);
            o += 2;
            if (o + nalSize > end) break;
            int type = p[o] & 0x1F;
            emit(copy(p, o, nalSize), type, ts);
            o += nalSize;
        }
    }

    // FU-A (RFC 6184 §5.8): FU indicator | FU header | fragment
    private void parseFuA(byte[] p, int off, int len, long ts) {
        if (len < 2) return;
        int fuIndicator = p[off] & 0xFF;
        int nri = fuIndicator & 0x60;
        int fuHeader = p[off + 1] & 0xFF;
        boolean start = (fuHeader & 0x80) != 0;
        boolean endBit = (fuHeader & 0x40) != 0;
        int nalType = fuHeader & 0x1F;

        if (start) {
            fuBuffer.reset();
            fuBuffer.write(nri | nalType);  // reconstruct NAL header byte
            fuTimestamp = ts;
            fuInProgress = true;
        }
        if (!fuInProgress) return;
        if (len > 2) fuBuffer.write(p, off + 2, len - 2);

        if (endBit) {
            byte[] nal = fuBuffer.toByteArray();
            int finalType = nal[0] & 0x1F;
            emit(nal, finalType, fuTimestamp);
            fuBuffer.reset();
            fuInProgress = false;
        }
    }

    // ────────────────────────────────────────────────
    //  H.265
    // ────────────────────────────────────────────────

    private void dispatchH265(byte[] p, int off, int len, long ts) {
        if (len < 2) return;
        int nalType = (p[off] >> 1) & 0x3F;
        if (nalType <= 47) {
            emit(copy(p, off, len), nalType, ts);
        } else if (nalType == 48) {
            parseH265AP(p, off, len, ts);
        } else if (nalType == 49) {
            parseH265FU(p, off, len, ts);
        }
    }

    // H.265 Aggregation Packet (RFC 7798 §4.4.2): 2-byte hdr, then [size16 | NAL]+
    private void parseH265AP(byte[] p, int off, int len, long ts) {
        int o = off + 2;
        int end = off + len;
        while (o + 2 <= end) {
            int nalSize = ((p[o] & 0xFF) << 8) | (p[o + 1] & 0xFF);
            o += 2;
            if (o + nalSize > end) break;
            int type = (p[o] >> 1) & 0x3F;
            emit(copy(p, o, nalSize), type, ts);
            o += nalSize;
        }
    }

    // H.265 Fragmentation Unit (RFC 7798 §4.4.3): 2-byte payload hdr | FU header | data
    private void parseH265FU(byte[] p, int off, int len, long ts) {
        if (len < 3) return;
        int hdr0 = p[off] & 0xFF;
        int hdr1 = p[off + 1] & 0xFF;
        int fuHeader = p[off + 2] & 0xFF;
        boolean start = (fuHeader & 0x80) != 0;
        boolean endBit = (fuHeader & 0x40) != 0;
        int nalType = fuHeader & 0x3F;

        if (start) {
            fuBuffer.reset();
            // Rebuild the 2-byte NAL header: keep F + LayerId bits, swap in the FU type.
            int reconHdr0 = (hdr0 & 0x81) | (nalType << 1);
            fuBuffer.write(reconHdr0);
            fuBuffer.write(hdr1);
            fuTimestamp = ts;
            fuInProgress = true;
        }
        if (!fuInProgress) return;
        if (len > 3) fuBuffer.write(p, off + 3, len - 3);

        if (endBit) {
            byte[] nal = fuBuffer.toByteArray();
            int finalType = (nal[0] >> 1) & 0x3F;
            emit(nal, finalType, fuTimestamp);
            fuBuffer.reset();
            fuInProgress = false;
        }
    }

    // ────────────────────────────────────────────────

    private void emit(byte[] nal, int type, long ts) {
        listener.onNalUnit(nal, type, ts);
    }

    private static byte[] copy(byte[] src, int off, int len) {
        byte[] out = new byte[len];
        System.arraycopy(src, off, out, 0, len);
        return out;
    }
}
