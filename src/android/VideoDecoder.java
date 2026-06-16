package com.andrewbal.rtspnativeplayer;

import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import android.view.Surface;

import java.nio.ByteBuffer;
import java.util.ArrayDeque;

/**
 * VideoDecoder — Java/MediaCodec port of the iOS VideoToolbox decoders.
 *
 * Configures a hardware H.264/H.265 decoder from in-band (or SDP) SPS/PPS(/VPS)
 * and renders every decoded frame to a Surface the instant it comes out
 * ({@code releaseOutputBuffer(index, true)}, no PTS scheduling). Combined with
 * KEY_LOW_LATENCY this is the Android equivalent of an AVSampleBufferDisplayLayer
 * with no control timebase: zero jitter buffer, lowest possible latency.
 *
 * Runs MediaCodec in asynchronous mode so input/output never block the network
 * thread. NAL units arrive via {@link #decode}; available input buffers and
 * pending NAL units are matched up in {@link #drain()}.
 */
public class VideoDecoder {

    private static final String TAG = "VideoDecoder";
    private static final byte[] START_CODE = {0x00, 0x00, 0x00, 0x01};
    private static final int MAX_PENDING = 120;  // guards against unbounded latency build-up

    public interface Listener {
        void onFirstFrame();
        void onVideoSize(int width, int height);
        void onError(String message);
    }

    private final boolean isH265;
    private final Listener listener;

    private MediaCodec codec;
    private HandlerThread codecThread;
    private Handler codecHandler;
    private volatile boolean released = false;
    private boolean firstFrameDelivered = false;

    private final Object lock = new Object();
    private final ArrayDeque<Integer> availableInputs = new ArrayDeque<>();
    private final ArrayDeque<Frame> pending = new ArrayDeque<>();

    private static class Frame {
        final byte[] data;
        final long ptsUs;
        final int flags;
        Frame(byte[] data, long ptsUs, int flags) {
            this.data = data;
            this.ptsUs = ptsUs;
            this.flags = flags;
        }
    }

    public VideoDecoder(boolean isH265, Listener listener) {
        this.isH265 = isH265;
        this.listener = listener;
    }

    /**
     * Configure and start the decoder. SPS/PPS are raw NAL units (no start code);
     * vps may be null for H.264.
     */
    public boolean configure(Surface surface, byte[] vps, byte[] sps, byte[] pps) {
        if (surface == null || sps == null || pps == null) return false;
        // Some cameras embed an Annex-B start code inside SDP sprop-parameter-sets.
        // Strip it so the csd ends up with exactly one start code, not two.
        vps = stripStartCode(vps);
        sps = stripStartCode(sps);
        pps = stripStartCode(pps);
        try {
            String mime = isH265 ? MediaFormat.MIMETYPE_VIDEO_HEVC : MediaFormat.MIMETYPE_VIDEO_AVC;
            // Placeholder dimensions — the real size comes from the csd/SPS and the
            // decoder reports it back via INFO_OUTPUT_FORMAT_CHANGED.
            MediaFormat format = MediaFormat.createVideoFormat(mime, 1280, 720);

            if (isH265) {
                // HEVC: csd-0 = VPS + SPS + PPS, each Annex-B framed.
                ByteBuffer csd = ByteBuffer.allocate(
                        (vps != null ? START_CODE.length + vps.length : 0)
                                + START_CODE.length + sps.length
                                + START_CODE.length + pps.length);
                if (vps != null) {
                    csd.put(START_CODE).put(vps);
                }
                csd.put(START_CODE).put(sps);
                csd.put(START_CODE).put(pps);
                csd.flip();
                format.setByteBuffer("csd-0", csd);
            } else {
                // AVC: csd-0 = SPS, csd-1 = PPS, each Annex-B framed.
                ByteBuffer csd0 = ByteBuffer.allocate(START_CODE.length + sps.length);
                csd0.put(START_CODE).put(sps).flip();
                format.setByteBuffer("csd-0", csd0);
                ByteBuffer csd1 = ByteBuffer.allocate(START_CODE.length + pps.length);
                csd1.put(START_CODE).put(pps).flip();
                format.setByteBuffer("csd-1", csd1);
            }

            // Large enough for a full-res I-frame so a single NAL never overflows
            // an input buffer (dashcams are 720p/1080p).
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 1024 * 1024);

            // Enable adaptive playback: this camera's SDP can advertise one resolution
            // (1280x720) while the actual in-band stream is another (640x360), so the
            // decoder must re-adapt on the first in-band SPS without a hard reconfigure.
            format.setInteger(MediaFormat.KEY_MAX_WIDTH, 1920);
            format.setInteger(MediaFormat.KEY_MAX_HEIGHT, 1088);

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
            }

            codecThread = new HandlerThread("VideoDecoder-codec");
            codecThread.start();
            codecHandler = new Handler(codecThread.getLooper());

            codec = MediaCodec.createDecoderByType(mime);
            codec.setCallback(callback, codecHandler);
            codec.configure(format, surface, null, 0);
            codec.start();

            Log.i(TAG, "Configured " + mime + " decoder ✓ (low-latency"
                    + (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ? "=on" : " n/a") + ")");
            return true;
        } catch (Exception e) {
            Log.e(TAG, "configure failed", e);
            listener.onError("Decoder init failed: " + e.getMessage());
            releaseInternal();
            return false;
        }
    }

    /** Queue a NAL unit (no start code) for decoding. */
    public void decode(byte[] nal, long timestamp90k, boolean keyframe) {
        if (released || codec == null) return;
        byte[] framed = new byte[START_CODE.length + nal.length];
        System.arraycopy(START_CODE, 0, framed, 0, START_CODE.length);
        System.arraycopy(nal, 0, framed, START_CODE.length, nal.length);

        long ptsUs = timestamp90k * 1000L / 90L;  // 90 kHz → microseconds
        int flags = keyframe ? MediaCodec.BUFFER_FLAG_KEY_FRAME : 0;

        synchronized (lock) {
            pending.add(new Frame(framed, ptsUs, flags));
            // Drop oldest if the producer outruns the decoder — keeps latency flat.
            while (pending.size() > MAX_PENDING) {
                pending.pollFirst();
            }
        }
        drain();
    }

    private final MediaCodec.Callback callback = new MediaCodec.Callback() {
        @Override
        public void onInputBufferAvailable(MediaCodec mc, int index) {
            synchronized (lock) {
                availableInputs.add(index);
            }
            drain();
        }

        @Override
        public void onOutputBufferAvailable(MediaCodec mc, int index, MediaCodec.BufferInfo info) {
            if (released) return;
            try {
                // Render immediately — no PTS gating. This is the low-latency path.
                mc.releaseOutputBuffer(index, true);
            } catch (IllegalStateException e) {
                return;
            }
            if (!firstFrameDelivered) {
                firstFrameDelivered = true;
                listener.onFirstFrame();
            }
        }

        @Override
        public void onOutputFormatChanged(MediaCodec mc, MediaFormat format) {
            try {
                int w = format.getInteger(MediaFormat.KEY_WIDTH);
                int h = format.getInteger(MediaFormat.KEY_HEIGHT);
                if (format.containsKey("crop-left") && format.containsKey("crop-right")) {
                    w = format.getInteger("crop-right") - format.getInteger("crop-left") + 1;
                }
                if (format.containsKey("crop-top") && format.containsKey("crop-bottom")) {
                    h = format.getInteger("crop-bottom") - format.getInteger("crop-top") + 1;
                }
                Log.i(TAG, "Output format: " + w + "x" + h);
                listener.onVideoSize(w, h);
            } catch (Exception ignored) {
            }
        }

        @Override
        public void onError(MediaCodec mc, MediaCodec.CodecException e) {
            Log.e(TAG, "Codec error", e);
            if (!released) listener.onError("Decoder error: " + e.getMessage());
        }
    };

    private void drain() {
        if (released) return;
        synchronized (lock) {
            MediaCodec mc = codec;
            if (mc == null) return;
            while (!availableInputs.isEmpty() && !pending.isEmpty()) {
                int index = availableInputs.poll();
                Frame f = pending.poll();
                try {
                    ByteBuffer buf = mc.getInputBuffer(index);
                    if (buf == null) continue;
                    if (f.data.length > buf.capacity()) {
                        Log.w(TAG, "NAL " + f.data.length + "B exceeds input buffer "
                                + buf.capacity() + "B — dropping");
                        continue;
                    }
                    buf.clear();
                    buf.put(f.data);
                    mc.queueInputBuffer(index, 0, f.data.length, f.ptsUs, f.flags);
                } catch (IllegalStateException e) {
                    return;  // codec released mid-drain
                }
            }
        }
    }

    /** Remove a leading Annex-B start code (00 00 00 01 or 00 00 01) if present. */
    private static byte[] stripStartCode(byte[] nal) {
        if (nal == null) return null;
        if (nal.length >= 4 && nal[0] == 0 && nal[1] == 0 && nal[2] == 0 && nal[3] == 1) {
            byte[] out = new byte[nal.length - 4];
            System.arraycopy(nal, 4, out, 0, out.length);
            return out;
        }
        if (nal.length >= 3 && nal[0] == 0 && nal[1] == 0 && nal[2] == 1) {
            byte[] out = new byte[nal.length - 3];
            System.arraycopy(nal, 3, out, 0, out.length);
            return out;
        }
        return nal;
    }

    public void release() {
        releaseInternal();
    }

    private void releaseInternal() {
        released = true;
        synchronized (lock) {
            pending.clear();
            availableInputs.clear();
        }
        if (codec != null) {
            try {
                codec.stop();
            } catch (Exception ignored) {
            }
            try {
                codec.release();
            } catch (Exception ignored) {
            }
            codec = null;
        }
        if (codecThread != null) {
            codecThread.quitSafely();
            codecThread = null;
        }
        codecHandler = null;
    }
}
