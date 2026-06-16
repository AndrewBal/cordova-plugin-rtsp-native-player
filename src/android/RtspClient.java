package com.andrewbal.rtspnativeplayer;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.Charset;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import javax.net.SocketFactory;

/**
 * RtspClient — Java port of the iOS RtspClient.
 *
 * Opens a raw TCP socket (bound to the Wi-Fi network so traffic never leaves
 * over cellular), performs the RTSP handshake OPTIONS → DESCRIBE → SETUP
 * (RTP/AVP/TCP interleaved) → PLAY, then continuously reads interleaved RTP
 * frames straight off the socket and hands the payloads to a listener.
 *
 * This is the low-latency analog of the Network.framework client on iOS:
 * there is NO jitter buffer and NO transcoding — RTP packets are delivered to
 * the depacketizer the instant they arrive.
 */
public class RtspClient {

    private static final String TAG = "RtspClient";
    private static final Charset ASCII = Charset.forName("US-ASCII");

    /** Parsed SDP video track. */
    public static class TrackInfo {
        public String codec;            // "H264" or "H265"
        public String controlUrl;       // e.g. "trackID=0"
        public int payloadType;
        public int clockRate = 90000;
        public String spropParameterSets; // H.264: base64 "SPS,PPS"
        public String spropVps;           // H.265
        public String spropSps;
        public String spropPps;
    }

    public interface Listener {
        void onConnecting();
        void onPlaying();
        void onTrackInfo(TrackInfo info);
        /** channel 0 = RTP video, channel 1 = RTCP. payload excludes the interleaved header. */
        void onRtpPacket(byte[] payload, int channel);
        void onError(String message);
        void onEnded();
    }

    private final Context appContext;
    private final String rtspUrl;
    private final Listener listener;

    private String host;
    private int port = 554;

    private volatile boolean stopped = false;
    private Thread netThread;
    private Socket socket;
    private InputStream in;
    private OutputStream out;
    private final Object writeLock = new Object();

    private int cseq = 0;
    private String sessionId;
    private TrackInfo videoTrack;

    // Accumulation buffer for partial TCP reads
    private final ByteArrayOutputStream acc = new ByteArrayOutputStream(65536);

    // Keepalive
    private Thread keepaliveThread;
    private long keepaliveIntervalMs = 3000;

    public RtspClient(Context context, String rtspUrl, Listener listener) {
        this.appContext = context.getApplicationContext();
        this.rtspUrl = rtspUrl;
        this.listener = listener;
        parseUrl(rtspUrl);
    }

    private void parseUrl(String url) {
        String s = url;
        if (s.startsWith("rtsp://")) s = s.substring(7);
        int slash = s.indexOf('/');
        String hostPort = slash >= 0 ? s.substring(0, slash) : s;
        int colon = hostPort.indexOf(':');
        if (colon >= 0) {
            host = hostPort.substring(0, colon);
            try {
                port = Integer.parseInt(hostPort.substring(colon + 1));
            } catch (NumberFormatException e) {
                port = 554;
            }
        } else {
            host = hostPort;
            port = 554;
        }
        Log.i(TAG, "Parsed URL: host=" + host + " port=" + port);
    }

    public void start() {
        stopped = false;
        netThread = new Thread(this::run, "RtspClient-net");
        netThread.start();
    }

    public void stop() {
        stopped = true;
        stopKeepalive();
        // Best-effort TEARDOWN so the camera frees the session promptly.
        try {
            if (out != null && sessionId != null) {
                String req = buildRequest("TEARDOWN", rtspUrl, "Session: " + sessionId + "\r\n");
                sendRaw(req);
            }
        } catch (Exception ignored) {
        }
        closeSocket();
        if (netThread != null) {
            netThread.interrupt();
            netThread = null;
        }
    }

    private void closeSocket() {
        try {
            if (socket != null) socket.close();
        } catch (Exception ignored) {
        }
        socket = null;
    }

    // ────────────────────────────────────────────────
    //  Network thread
    // ────────────────────────────────────────────────

    private void run() {
        try {
            listener.onConnecting();
            connectTcp();
            if (stopped) return;

            handshakeOptions();
            handshakeDescribe();
            handshakeSetup();
            handshakePlay();

            // PLAY succeeded → camera now streams interleaved RTP. Drain any
            // bytes already buffered from the PLAY response, then loop forever.
            startKeepalive();
            listener.onPlaying();

            processInterleaved();
            readInterleavedLoop();
        } catch (StoppedException e) {
            // normal shutdown
        } catch (Exception e) {
            if (!stopped) {
                Log.e(TAG, "RTSP error", e);
                listener.onError(e.getMessage() != null ? e.getMessage() : "RTSP failed");
            }
        }
    }

    private static class StoppedException extends Exception {}

    private void connectTcp() throws Exception {
        Log.i(TAG, "Connecting TCP to " + host + ":" + port + " (Wi-Fi bound)");
        Network wifi = pickWifiNetwork();
        SocketFactory factory = wifi != null ? wifi.getSocketFactory() : SocketFactory.getDefault();
        if (wifi == null) {
            Log.w(TAG, "No Wi-Fi network found — socket may route over cellular");
        }
        socket = factory.createSocket();
        socket.setTcpNoDelay(true);          // no Nagle → minimal latency
        socket.connect(new InetSocketAddress(host, port), 8000);
        socket.setSoTimeout(15000);
        in = socket.getInputStream();
        out = socket.getOutputStream();
        Log.i(TAG, "TCP connected ✓");
    }

    private Network pickWifiNetwork() {
        try {
            ConnectivityManager cm =
                    (ConnectivityManager) appContext.getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm == null) return null;
            for (Network n : cm.getAllNetworks()) {
                NetworkCapabilities caps = cm.getNetworkCapabilities(n);
                if (caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                    return n;
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "pickWifiNetwork failed: " + e.getMessage());
        }
        return null;
    }

    // ────────────────────────────────────────────────
    //  RTSP handshake
    // ────────────────────────────────────────────────

    private String buildRequest(String method, String url, String extraHeaders) {
        cseq++;
        StringBuilder sb = new StringBuilder();
        sb.append(method).append(' ').append(url).append(" RTSP/1.0\r\n");
        sb.append("CSeq: ").append(cseq).append("\r\n");
        sb.append("User-Agent: QuikVizn/1.0\r\n");
        if (extraHeaders != null) sb.append(extraHeaders);
        sb.append("\r\n");
        return sb.toString();
    }

    private void sendRaw(String request) throws Exception {
        synchronized (writeLock) {
            if (out == null) return;
            out.write(request.getBytes(ASCII));
            out.flush();
        }
    }

    private void handshakeOptions() throws Exception {
        sendRaw(buildRequest("OPTIONS", rtspUrl, null));
        String resp = readRtspResponse();
        requireOk(resp, "OPTIONS");
        Log.i(TAG, "OPTIONS OK ✓");
    }

    private void handshakeDescribe() throws Exception {
        sendRaw(buildRequest("DESCRIBE", rtspUrl, "Accept: application/sdp\r\n"));
        String resp = readRtspResponse();
        requireOk(resp, "DESCRIBE");
        Log.i(TAG, "DESCRIBE OK ✓");

        TrackInfo track = parseSdp(resp);
        if (track == null) throw new Exception("No H.264/H.265 video track in SDP");
        videoTrack = track;
        listener.onTrackInfo(track);
    }

    private void handshakeSetup() throws Exception {
        String control = videoTrack.controlUrl != null ? videoTrack.controlUrl : "trackID=0";
        String setupUrl = control.startsWith("rtsp://") ? control : rtspUrl + "/" + control;
        sendRaw(buildRequest("SETUP", setupUrl,
                "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n"));
        String resp = readRtspResponse();
        requireOk(resp, "SETUP");

        Matcher m = Pattern.compile("Session:\\s*([^;\\r\\n]+)").matcher(resp);
        if (m.find()) sessionId = m.group(1).trim();
        Log.i(TAG, "SETUP OK ✓ session=" + sessionId);
    }

    private void handshakePlay() throws Exception {
        String headers = sessionId != null
                ? "Session: " + sessionId + "\r\nRange: npt=0.000-\r\n"
                : "Range: npt=0.000-\r\n";
        sendRaw(buildRequest("PLAY", rtspUrl, headers));
        String resp = readRtspResponse();
        requireOk(resp, "PLAY");
        Log.i(TAG, "PLAY OK ✓ — entering RTP receive mode");
    }

    private void requireOk(String response, String method) throws Exception {
        int code = parseStatusCode(response);
        if (code != 200) throw new Exception(method + " failed (status=" + code + ")");
    }

    private int parseStatusCode(String response) {
        Matcher m = Pattern.compile("RTSP/1\\.0\\s+(\\d+)").matcher(response);
        if (m.find()) {
            try {
                return Integer.parseInt(m.group(1));
            } catch (NumberFormatException ignored) {
            }
        }
        return -1;
    }

    /**
     * Read one complete RTSP text response (header + optional Content-Length body)
     * from the socket, leaving any trailing bytes in {@link #acc}.
     */
    private String readRtspResponse() throws Exception {
        byte[] tmp = new byte[8192];
        while (true) {
            byte[] buf = acc.toByteArray();
            int headerEnd = indexOf(buf, "\r\n\r\n".getBytes(ASCII), 0);
            if (headerEnd >= 0) {
                String headers = new String(buf, 0, headerEnd, ASCII);
                int contentLength = 0;
                Matcher m = Pattern.compile("Content-[Ll]ength:\\s*(\\d+)").matcher(headers);
                if (m.find()) contentLength = Integer.parseInt(m.group(1));
                int total = headerEnd + 4 + contentLength;
                if (buf.length >= total) {
                    String response = new String(buf, 0, total, ASCII);
                    // keep leftover
                    acc.reset();
                    if (buf.length > total) acc.write(buf, total, buf.length - total);
                    return response;
                }
            }
            if (stopped) throw new StoppedException();
            int n = in.read(tmp);
            if (n < 0) throw new Exception("Connection closed during handshake");
            acc.write(tmp, 0, n);
        }
    }

    // ────────────────────────────────────────────────
    //  Interleaved RTP reader
    // ────────────────────────────────────────────────

    private void readInterleavedLoop() throws Exception {
        byte[] tmp = new byte[65536];
        while (!stopped) {
            int n;
            try {
                n = in.read(tmp);
            } catch (java.net.SocketTimeoutException te) {
                // No data within SoTimeout. Keepalive keeps the session alive; loop.
                continue;
            }
            if (n < 0) {
                if (!stopped) listener.onEnded();
                return;
            }
            acc.write(tmp, 0, n);
            processInterleaved();
        }
    }

    /**
     * Extract complete interleaved frames ($ | channel | len16 | payload) from the
     * accumulation buffer, mirroring the iOS implementation. Non-$ runs (RTSP
     * keepalive replies that arrive on the same socket) are skipped.
     */
    private void processInterleaved() {
        byte[] buf = acc.toByteArray();
        int len = buf.length;
        int offset = 0;

        while (offset < len) {
            if (len - offset < 4) break;

            if ((buf[offset] & 0xFF) != 0x24) {  // not '$' → skip to next '$'
                int scanStart = offset;
                while (offset < len && (buf[offset] & 0xFF) != 0x24) offset++;
                if (offset > scanStart && offset - scanStart < 512) {
                    Log.d(TAG, "Skipped " + (offset - scanStart) + " non-interleaved bytes");
                }
                continue;
            }

            int channel = buf[offset + 1] & 0xFF;
            int frameLen = ((buf[offset + 2] & 0xFF) << 8) | (buf[offset + 3] & 0xFF);

            if (frameLen == 0) {
                offset++;
                continue;
            }
            if (len - offset < 4 + frameLen) break;  // wait for more data

            byte[] payload = new byte[frameLen];
            System.arraycopy(buf, offset + 4, payload, 0, frameLen);
            offset += 4 + frameLen;

            listener.onRtpPacket(payload, channel);
        }

        // Keep unconsumed tail
        acc.reset();
        if (offset < len) acc.write(buf, offset, len - offset);
    }

    private static int indexOf(byte[] haystack, byte[] needle, int from) {
        outer:
        for (int i = Math.max(0, from); i <= haystack.length - needle.length; i++) {
            for (int j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) continue outer;
            }
            return i;
        }
        return -1;
    }

    // ────────────────────────────────────────────────
    //  SDP parsing
    // ────────────────────────────────────────────────

    private TrackInfo parseSdp(String response) {
        int bodyStart = response.indexOf("\r\n\r\n");
        if (bodyStart < 0) return null;
        String sdp = response.substring(bodyStart + 4);
        Log.i(TAG, "SDP:\n" + sdp);

        boolean inVideo = false;
        TrackInfo track = null;

        for (String raw : sdp.split("\n")) {
            String line = raw.trim();
            if (line.startsWith("m=video")) {
                inVideo = true;
                track = new TrackInfo();
                String[] parts = line.split(" ");
                if (parts.length >= 4) {
                    try {
                        track.payloadType = Integer.parseInt(parts[3]);
                    } catch (NumberFormatException ignored) {
                    }
                }
                continue;
            }
            if (line.startsWith("m=")) {
                if (inVideo && track != null) break;
                inVideo = false;
                continue;
            }
            if (!inVideo || track == null) continue;

            if (line.startsWith("a=rtpmap:")) {
                Matcher m = Pattern.compile("a=rtpmap:\\d+\\s+(\\w+)/(\\d+)").matcher(line);
                if (m.find()) {
                    track.codec = m.group(1);
                    track.clockRate = Integer.parseInt(m.group(2));
                }
            } else if (line.startsWith("a=fmtp:")) {
                Matcher sp = Pattern.compile("sprop-parameter-sets=([^;\\s]+)").matcher(line);
                if (sp.find()) track.spropParameterSets = sp.group(1);
                Matcher vps = Pattern.compile("sprop-vps=([^;\\s]+)").matcher(line);
                if (vps.find()) track.spropVps = vps.group(1);
                Matcher sps = Pattern.compile("sprop-sps=([^;\\s]+)").matcher(line);
                if (sps.find()) track.spropSps = sps.group(1);
                Matcher pps = Pattern.compile("sprop-pps=([^;\\s]+)").matcher(line);
                if (pps.find()) track.spropPps = pps.group(1);
            } else if (line.startsWith("a=control:")) {
                track.controlUrl = line.substring("a=control:".length());
            }
        }

        if (track != null && track.codec != null) {
            String c = track.codec.toUpperCase();
            if (c.equals("H264") || c.equals("H265") || c.equals("HEVC")) {
                if (track.clockRate == 0) track.clockRate = 90000;
                return track;
            }
        }
        return null;
    }

    // ────────────────────────────────────────────────
    //  Keepalive (GET_PARAMETER every ~3s)
    // ────────────────────────────────────────────────

    private void startKeepalive() {
        stopKeepalive();
        keepaliveThread = new Thread(() -> {
            while (!stopped) {
                try {
                    Thread.sleep(keepaliveIntervalMs);
                } catch (InterruptedException e) {
                    return;
                }
                if (stopped) return;
                try {
                    String headers = sessionId != null ? "Session: " + sessionId + "\r\n" : "";
                    sendRaw(buildRequest("GET_PARAMETER", rtspUrl, headers));
                } catch (Exception e) {
                    Log.w(TAG, "Keepalive send failed: " + e.getMessage());
                }
            }
        }, "RtspClient-keepalive");
        keepaliveThread.start();
    }

    private void stopKeepalive() {
        if (keepaliveThread != null) {
            keepaliveThread.interrupt();
            keepaliveThread = null;
        }
    }
}
