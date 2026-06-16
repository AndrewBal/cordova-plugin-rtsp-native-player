package com.andrewbal.rtspnativeplayer;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import android.util.Log;
import android.view.Gravity;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * RtspNativePlayerActivity — native, zero-buffering RTSP player.
 *
 * Mirrors the iOS pipeline (RtspClient → RtpParser → VideoToolbox →
 * AVSampleBufferDisplayLayer) with the Android equivalents:
 *   RtspClient (raw TCP/RTSP, interleaved RTP) → RtpDepacketizer →
 *   VideoDecoder (MediaCodec → Surface, render-on-decode).
 *
 * No ExoPlayer, no libVLC, no FFmpeg/HLS — therefore no transcoding and no
 * jitter buffer. RTP packets are decoded and shown the instant they arrive.
 */
public class RtspNativePlayerActivity extends Activity implements
        RtspClient.Listener, RtpDepacketizer.Listener, VideoDecoder.Listener {

    private static final String TAG = "RtspNativePlayer";
    private static RtspNativePlayerActivity currentActivity;

    private FrameLayout root;
    private SurfaceView surfaceView;
    private ProgressBar loadingIndicator;
    private TextView statusLabel;
    private TextView cameraLabel;
    private TextView recordingIndicator;
    private Button recordButton;
    private Button switchButton;

    // Native pipeline
    private volatile RtspClient rtspClient;
    private volatile RtpDepacketizer depacketizer;
    private volatile VideoDecoder decoder;
    private final Object pipelineLock = new Object();
    private volatile android.view.Surface surface;
    private volatile boolean surfaceReady = false;
    private volatile boolean isH265 = false;
    private volatile boolean decoderConfigured = false;
    private volatile byte[] sps, pps, vps;
    private int videoWidth, videoHeight;

    private String frontUrl;
    private String rearUrl;
    private String titleText;
    private String apiBaseUrl;
    private String deviceType;
    private String currentCamera = "front";
    private boolean isRecording = false;
    private boolean isSwitchingCamera = false;
    private boolean closed = false;

    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final ExecutorService executor = Executors.newSingleThreadExecutor();

    public static RtspNativePlayerActivity getCurrentActivity() {
        return currentActivity;
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        currentActivity = this;

        requestWindowFeature(Window.FEATURE_NO_TITLE);
        getWindow().setFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN, WindowManager.LayoutParams.FLAG_FULLSCREEN);
        hideSystemUi();

        frontUrl = getIntent().getStringExtra("frontUrl");
        rearUrl = getIntent().getStringExtra("rearUrl");
        titleText = getIntent().getStringExtra("title");
        apiBaseUrl = getIntent().getStringExtra("apiBaseUrl");
        deviceType = getIntent().getStringExtra("deviceType");
        if (deviceType == null) deviceType = "";

        if (titleText == null || titleText.length() == 0) titleText = "Live";
        if (apiBaseUrl == null || apiBaseUrl.length() == 0) apiBaseUrl = "http://192.168.0.1";

        Log.i(TAG, "Starting native player. frontUrl=" + frontUrl + ", rearUrl=" + rearUrl
                + ", apiBaseUrl=" + apiBaseUrl + ", deviceType=" + deviceType);

        buildUi();
        if ("lombotech".equals(deviceType)) {
            startLombotechHeartbeat();
        }
        if ("lombotech".equals(deviceType) || (rearUrl != null && rearUrl.length() > 0)) {
            checkCameraCount();
        }
        // Playback starts in surfaceCreated() once we have a valid Surface.
    }

    private void hideSystemUi() {
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        | View.SYSTEM_UI_FLAG_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
        );
    }

    private void buildUi() {
        root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        setContentView(root, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
        ));

        surfaceView = new SurfaceView(this);
        FrameLayout.LayoutParams surfaceParams = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT);
        surfaceParams.gravity = Gravity.CENTER;
        root.addView(surfaceView, surfaceParams);
        surfaceView.getHolder().addCallback(new SurfaceHolder.Callback() {
            @Override
            public void surfaceCreated(SurfaceHolder holder) {
                surface = holder.getSurface();
                surfaceReady = true;
                if (!closed && rtspClient == null) {
                    startPipeline(frontUrl);
                } else {
                    maybeConfigureDecoder();
                }
            }

            @Override
            public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
                surface = holder.getSurface();
            }

            @Override
            public void surfaceDestroyed(SurfaceHolder holder) {
                surfaceReady = false;
                surface = null;
                stopPipeline();
            }
        });

        loadingIndicator = new ProgressBar(this);
        FrameLayout.LayoutParams progressParams = new FrameLayout.LayoutParams(dp(52), dp(52));
        progressParams.gravity = Gravity.CENTER;
        root.addView(loadingIndicator, progressParams);

        statusLabel = new TextView(this);
        statusLabel.setText("Connecting...");
        statusLabel.setTextColor(Color.LTGRAY);
        statusLabel.setTextSize(14);
        statusLabel.setGravity(Gravity.CENTER);
        FrameLayout.LayoutParams statusParams = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(60)
        );
        statusParams.gravity = Gravity.CENTER;
        statusParams.leftMargin = dp(24);
        statusParams.rightMargin = dp(24);
        statusParams.topMargin = dp(78);
        root.addView(statusLabel, statusParams);

        LinearLayout topBar = new LinearLayout(this);
        topBar.setOrientation(LinearLayout.HORIZONTAL);
        topBar.setGravity(Gravity.CENTER_VERTICAL);
        topBar.setPadding(dp(12), dp(10), dp(12), dp(10));
        topBar.setBackgroundColor(Color.argb(115, 0, 0, 0));
        FrameLayout.LayoutParams topParams = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(72)
        );
        topParams.gravity = Gravity.TOP;
        root.addView(topBar, topParams);

        Button closeButton = createRoundButton("✕", 44, Color.TRANSPARENT, Color.WHITE, 24);
        closeButton.setOnClickListener(v -> finishPlayer());
        topBar.addView(closeButton, new LinearLayout.LayoutParams(dp(54), dp(54)));

        TextView titleLabel = new TextView(this);
        titleLabel.setText(titleText);
        titleLabel.setTextColor(Color.WHITE);
        titleLabel.setTextSize(18);
        titleLabel.setGravity(Gravity.CENTER);
        titleLabel.setSingleLine(true);
        topBar.addView(titleLabel, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));

        recordingIndicator = new TextView(this);
        recordingIndicator.setText("● REC");
        recordingIndicator.setTextColor(Color.RED);
        recordingIndicator.setTextSize(14);
        recordingIndicator.setGravity(Gravity.CENTER);
        recordingIndicator.setVisibility(View.GONE);
        topBar.addView(recordingIndicator, new LinearLayout.LayoutParams(dp(70), dp(40)));

        cameraLabel = new TextView(this);
        cameraLabel.setText("Front");
        cameraLabel.setTextColor(Color.WHITE);
        cameraLabel.setTextSize(13);
        cameraLabel.setGravity(Gravity.CENTER);
        cameraLabel.setBackground(makeRoundedBg(Color.argb(60, 255, 255, 255), dp(18)));
        cameraLabel.setVisibility(View.GONE);
        topBar.addView(cameraLabel, new LinearLayout.LayoutParams(dp(76), dp(36)));

        LinearLayout bottomControls = new LinearLayout(this);
        bottomControls.setOrientation(LinearLayout.HORIZONTAL);
        bottomControls.setGravity(Gravity.CENTER);
        bottomControls.setPadding(dp(16), dp(22), dp(16), dp(22));
        bottomControls.setBackgroundColor(Color.argb(115, 0, 0, 0));
        FrameLayout.LayoutParams bottomParams = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(120)
        );
        bottomParams.gravity = Gravity.BOTTOM;
        root.addView(bottomControls, bottomParams);

        Button photoButton = createRoundButton("📷", 60, Color.WHITE, Color.BLACK, 24);
        photoButton.setOnClickListener(v -> takePhoto());
        bottomControls.addView(photoButton, controlButtonParams());

        recordButton = createRoundButton("●", 60, Color.WHITE, Color.BLACK, 30);
        recordButton.setOnClickListener(v -> toggleRecording());
        bottomControls.addView(recordButton, controlButtonParams());

        switchButton = createRoundButton("⇄", 60, Color.WHITE, Color.BLACK, 28);
        switchButton.setVisibility(View.GONE);
        switchButton.setOnClickListener(v -> switchCamera());
        bottomControls.addView(switchButton, controlButtonParams());
    }

    private LinearLayout.LayoutParams controlButtonParams() {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(dp(60), dp(60));
        params.leftMargin = dp(15);
        params.rightMargin = dp(15);
        return params;
    }

    private Button createRoundButton(String text, int sizeDp, int bgColor, int textColor, int textSizeSp) {
        Button button = new Button(this);
        button.setText(text);
        button.setTextSize(textSizeSp);
        button.setTextColor(textColor);
        button.setGravity(Gravity.CENTER);
        button.setAllCaps(false);
        button.setPadding(0, 0, 0, 0);
        button.setMinWidth(0);
        button.setMinHeight(0);
        button.setBackground(makeRoundedBg(bgColor, dp(sizeDp / 2)));
        return button;
    }

    private GradientDrawable makeRoundedBg(int color, int radius) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(color);
        drawable.setCornerRadius(radius);
        return drawable;
    }

    // ────────────────────────────────────────────────
    //  Native pipeline lifecycle
    // ────────────────────────────────────────────────

    private void startPipeline(String url) {
        synchronized (pipelineLock) {
            if (rtspClient != null) return;
            decoderConfigured = false;
            sps = pps = vps = null;
            isH265 = false;
            depacketizer = new RtpDepacketizer(this);
            rtspClient = new RtspClient(getApplicationContext(), url, this);
            rtspClient.start();
        }
        setStatus("CONNECTING", null, "Connecting...");
        showLoading(true);
    }

    private void stopPipeline() {
        RtspClient client;
        VideoDecoder dec;
        synchronized (pipelineLock) {
            client = rtspClient;
            dec = decoder;
            rtspClient = null;
            decoder = null;
            depacketizer = null;
            decoderConfigured = false;
            sps = pps = vps = null;
        }
        if (client != null) client.stop();
        if (dec != null) dec.release();
    }

    private void maybeConfigureDecoder() {
        synchronized (pipelineLock) {
            if (decoder == null || decoderConfigured || !surfaceReady || surface == null) return;
            if (sps == null || pps == null) return;
            if (isH265 && vps == null) return;
            boolean ok = decoder.configure(surface, vps, sps, pps);
            decoderConfigured = ok;
            if (ok) Log.i(TAG, "Decoder configured (" + (isH265 ? "H265" : "H264") + ")");
        }
    }

    // ── RtspClient.Listener ──────────────────────────

    @Override
    public void onConnecting() {
        setStatus("CONNECTING", null, "Connecting...");
    }

    @Override
    public void onPlaying() {
        setStatus("BUFFERING", null, "Receiving stream...");
    }

    @Override
    public void onTrackInfo(RtspClient.TrackInfo info) {
        String codec = info.codec != null ? info.codec.toUpperCase() : "H264";
        isH265 = codec.equals("H265") || codec.equals("HEVC");
        synchronized (pipelineLock) {
            if (depacketizer != null) depacketizer.setH265(isH265);
            decoder = new VideoDecoder(isH265, this);
        }
        // Seed param sets from SDP if present (in-band NALs still override/confirm).
        if (isH265) {
            if (info.spropVps != null) vps = decodeB64(info.spropVps);
            if (info.spropSps != null) sps = decodeB64(info.spropSps);
            if (info.spropPps != null) pps = decodeB64(info.spropPps);
        } else if (info.spropParameterSets != null) {
            String[] parts = info.spropParameterSets.split(",");
            if (parts.length >= 1) sps = decodeB64(parts[0]);
            if (parts.length >= 2) pps = decodeB64(parts[1]);
        }
        maybeConfigureDecoder();
    }

    @Override
    public void onRtpPacket(byte[] payload, int channel) {
        // RtspClient already filtered to the negotiated video RTP channel.
        RtpDepacketizer d = depacketizer;
        if (d != null) d.feed(payload);
    }

    @Override
    public void onError(String message) {
        Log.e(TAG, "Pipeline error: " + message);
        showStatusText("Stream error");
        RtspHlsPlayer.sendErrorToJs(message);
    }

    @Override
    public void onEnded() {
        Log.w(TAG, "Stream ended");
        showStatusText("Stream ended");
    }

    // ── RtpDepacketizer.Listener ─────────────────────

    private int nalLogCount = 0;

    @Override
    public void onNalUnit(byte[] nal, int type, long timestamp) {
        if (nalLogCount < 12) {
            nalLogCount++;
            Log.i(TAG, "NAL type=" + type + " len=" + nal.length + " (configured=" + decoderConfigured + ")");
        }
        if (isH265) {
            handleH265Nal(nal, type, timestamp);
        } else {
            handleH264Nal(nal, type, timestamp);
        }
    }

    private void handleH264Nal(byte[] nal, int type, long ts) {
        switch (type) {
            case 7:  // SPS — keep for the initial csd AND feed it so the decoder can
                sps = nal;            // adapt to in-band resolution (SDP often lies, e.g.
                maybeConfigureDecoder();   // advertises 1280x720 while the stream is 640x360)
                decodeIfReady(nal, ts, false);
                break;
            case 8:  // PPS
                pps = nal;
                maybeConfigureDecoder();
                decodeIfReady(nal, ts, false);
                break;
            case 5:  // IDR
                decodeIfReady(nal, ts, true);
                break;
            case 1:  // non-IDR slice
                decodeIfReady(nal, ts, false);
                break;
            default:
                break;  // SEI/etc. — ignore
        }
    }

    private void handleH265Nal(byte[] nal, int type, long ts) {
        switch (type) {
            case 32:  // VPS
                vps = nal;
                maybeConfigureDecoder();
                break;
            case 33:  // SPS
                sps = nal;
                maybeConfigureDecoder();
                break;
            case 34:  // PPS
                pps = nal;
                maybeConfigureDecoder();
                break;
            case 19:  // IDR_W_RADL
            case 20:  // IDR_N_LP
            case 21:  // CRA
                decodeIfReady(nal, ts, true);
                break;
            case 39:  // PREFIX_SEI
            case 40:  // SUFFIX_SEI
                break;
            default:
                if (type <= 31) decodeIfReady(nal, ts, false);
                break;
        }
    }

    private void decodeIfReady(byte[] nal, long ts, boolean keyframe) {
        VideoDecoder d = decoder;
        if (decoderConfigured && d != null) d.decode(nal, ts, keyframe);
    }

    // ── VideoDecoder.Listener ────────────────────────

    @Override
    public void onFirstFrame() {
        setStatus("PLAYING", null, "");
        showLoading(false);
    }

    @Override
    public void onVideoSize(int width, int height) {
        videoWidth = width;
        videoHeight = height;
        applyAspect();
    }

    private void applyAspect() {
        mainHandler.post(() -> {
            if (videoWidth <= 0 || videoHeight <= 0 || root == null || surfaceView == null) return;
            int rw = root.getWidth();
            int rh = root.getHeight();
            if (rw <= 0 || rh <= 0) return;
            float scale = Math.min((float) rw / videoWidth, (float) rh / videoHeight);
            int w = Math.round(videoWidth * scale);
            int h = Math.round(videoHeight * scale);
            FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(w, h);
            lp.gravity = Gravity.CENTER;
            surfaceView.setLayoutParams(lp);
        });
    }

    private byte[] decodeB64(String s) {
        try {
            return Base64.decode(s.trim(), Base64.DEFAULT);
        } catch (Exception e) {
            return null;
        }
    }

    // ────────────────────────────────────────────────
    //  Camera controls (HTTP) — unchanged from the prior engine
    // ────────────────────────────────────────────────

    private void takePhoto() {
        showToast("Taking photo...");
        RtspHlsPlayer.sendActionToJs("PHOTO", currentCamera, null);

        sendCameraCommand("/app/snapshot", "trigger", () -> {
            showToast("Photo saved!");
            RtspHlsPlayer.sendActionToJs("PHOTO_SUCCESS", currentCamera, null);
        }, () -> {
            showToast("Photo failed");
            RtspHlsPlayer.sendActionToJs("PHOTO_FAILED", currentCamera, null);
        });
    }

    private void toggleRecording() {
        boolean start = !isRecording;
        showToast(start ? "Starting..." : "Stopping...");

        sendCameraCommand(
            start ? "/app/setparamvalue?param=rec&value=1" : "/app/setparamvalue?param=rec&value=0",
            start ? "start" : "stop",
            () -> {
                isRecording = start;
                recordingIndicator.setVisibility(isRecording ? View.VISIBLE : View.GONE);
                recordButton.setTextColor(isRecording ? Color.WHITE : Color.BLACK);
                recordButton.setBackground(makeRoundedBg(isRecording ? Color.RED : Color.WHITE, dp(30)));
                showToast(start ? "Recording" : "Stopped");
                RtspHlsPlayer.sendActionToJs(start ? "RECORD_START" : "RECORD_STOP", currentCamera, null);
            }, () -> showToast("Failed"));
    }

    private void switchCamera() {
        if (isSwitchingCamera) return;

        isSwitchingCamera = true;
        String newCamera = "front".equals(currentCamera) ? "rear" : "front";
        int camId = "front".equals(newCamera) ? 0 : 1;

        showToast("Switching camera...");
        setStatus("SWITCHING_CAMERA", newCamera, "Switching camera...");
        showLoading(true);
        stopPipeline();

        String switchUrl = "lombotech".equals(deviceType)
                ? apiBaseUrl + "/app/setparamvalue?param=switchcam&value=" + camId
                : apiBaseUrl + "/cgi-bin/hisnet/getcamchnl.cgi?&-camid=" + camId;
        httpGet(switchUrl, response -> mainHandler.post(() -> {
            currentCamera = newCamera;
            cameraLabel.setText("front".equals(currentCamera) ? "Front" : "Rear");
            RtspHlsPlayer.sendActionToJs("CAMERA_SWITCHED", currentCamera, null);
            long restartDelayMs = "lombotech".equals(deviceType) ? 1200 : 500;
            Log.i(TAG, "Camera switch OK. Restarting pipeline in " + restartDelayMs + "ms");
            isSwitchingCamera = false;
            mainHandler.postDelayed(() -> { if (!closed) startPipeline(frontUrl); }, restartDelayMs);
        }), () -> mainHandler.post(() -> {
            showToast("Failed to switch camera");
            long restartDelayMs = "lombotech".equals(deviceType) ? 1200 : 500;
            isSwitchingCamera = false;
            mainHandler.postDelayed(() -> { if (!closed) startPipeline(frontUrl); }, restartDelayMs);
        }));
    }

    // Lombotech RTSP keepalive lives in the native activity because the WebView is
    // paused while this Activity is foregrounded; the camera drops the RTSP session
    // after ~10s without a heartbeat.
    private Handler heartbeatHandler;
    private Runnable heartbeatRunnable;

    private void startLombotechHeartbeat() {
        stopLombotechHeartbeat();
        heartbeatHandler = new Handler(Looper.getMainLooper());
        heartbeatRunnable = new Runnable() {
            @Override
            public void run() {
                httpGet(
                        apiBaseUrl + "/app/getparamvalue?param=rec",
                        resp -> {},
                        () -> Log.w(TAG, "Lombotech heartbeat failed")
                );
                if (heartbeatHandler != null) heartbeatHandler.postDelayed(this, 3000);
            }
        };
        heartbeatHandler.post(heartbeatRunnable);
    }

    private void stopLombotechHeartbeat() {
        if (heartbeatHandler != null && heartbeatRunnable != null) {
            heartbeatHandler.removeCallbacks(heartbeatRunnable);
        }
        heartbeatHandler = null;
        heartbeatRunnable = null;
    }

    private void checkCameraCount() {
        String url = "lombotech".equals(deviceType)
                ? apiBaseUrl + "/app/getdeviceattr"
                : apiBaseUrl + "/cgi-bin/hisnet/getcamnum.cgi";
        httpGet(url, response -> mainHandler.post(() -> {
            int count = "lombotech".equals(deviceType)
                    ? parseLombotechCamnum(response)
                    : parseCameraCount(response);
            if (count >= 2) setCameraCount(count);
        }), () -> {});
    }

    private int parseCameraCount(String response) {
        if (response == null) return 0;
        String marker = "camnum=\"";
        int start = response.indexOf(marker);
        if (start < 0) return 0;
        start += marker.length();
        int end = response.indexOf("\"", start);
        if (end <= start) return 0;
        try {
            return Integer.parseInt(response.substring(start, end));
        } catch (Exception e) {
            return 0;
        }
    }

    private int parseLombotechCamnum(String response) {
        if (response == null) return 0;
        try {
            org.json.JSONObject json = new org.json.JSONObject(response);
            org.json.JSONObject info = json.optJSONObject("info");
            return info != null ? info.optInt("camnum", 0) : json.optInt("camnum", 0);
        } catch (Exception e) {
            return 0;
        }
    }

    private void setCameraCount(int count) {
        if (count >= 2 || "lombotech".equals(deviceType) || (rearUrl != null && rearUrl.length() > 0)) {
            switchButton.setVisibility(View.VISIBLE);
            cameraLabel.setVisibility(View.VISIBLE);
        }
    }

    private void sendCameraCommand(String lomboEndpoint, String hisnetCmd, Runnable success, Runnable failure) {
        String url = "lombotech".equals(deviceType)
                ? apiBaseUrl + lomboEndpoint
                : apiBaseUrl + "/cgi-bin/hisnet/workmodecmd.cgi?-cmd=" + hisnetCmd;
        httpGet(url, response -> mainHandler.post(success), () -> mainHandler.post(failure));
    }

    private interface HttpSuccess {
        void onSuccess(String response);
    }

    private void httpGet(String urlString, HttpSuccess success, Runnable failure) {
        executor.execute(() -> {
            HttpURLConnection connection = null;
            try {
                URL url = new URL(urlString);
                connection = (HttpURLConnection) url.openConnection();
                connection.setConnectTimeout(5000);
                connection.setReadTimeout(5000);
                connection.setUseCaches(false);
                connection.setRequestMethod("GET");

                int code = connection.getResponseCode();
                InputStream inputStream = code >= 200 && code < 300
                        ? connection.getInputStream()
                        : connection.getErrorStream();
                String response = readStream(inputStream);

                if (code >= 200 && code < 300) {
                    success.onSuccess(response);
                } else {
                    failure.run();
                }
            } catch (Exception e) {
                failure.run();
            } finally {
                if (connection != null) connection.disconnect();
            }
        });
    }

    private String readStream(InputStream inputStream) throws Exception {
        if (inputStream == null) return "";
        BufferedReader reader = new BufferedReader(new InputStreamReader(inputStream));
        StringBuilder builder = new StringBuilder();
        String line;
        while ((line = reader.readLine()) != null) {
            builder.append(line);
        }
        reader.close();
        return builder.toString();
    }

    // ────────────────────────────────────────────────
    //  Status / UI helpers
    // ────────────────────────────────────────────────

    private void setStatus(String value, String message, String uiText) {
        RtspHlsPlayer.sendStatusToJs(value, message, true);
        showStatusText(uiText);
    }

    private void showStatusText(String text) {
        mainHandler.post(() -> {
            if (text == null || text.length() == 0) {
                statusLabel.setVisibility(View.GONE);
            } else {
                statusLabel.setVisibility(View.VISIBLE);
                statusLabel.setText(text);
            }
        });
    }

    private void showLoading(boolean show) {
        mainHandler.post(() -> loadingIndicator.setVisibility(show ? View.VISIBLE : View.GONE));
    }

    private void showToast(String message) {
        mainHandler.post(() -> Toast.makeText(this, message, Toast.LENGTH_SHORT).show());
    }

    private void finishPlayer() {
        if (closed) return;
        closed = true;
        stopLombotechHeartbeat();
        stopPipeline();
        RtspHlsPlayer.sendStatusToJs("CLOSED", null, false);
        finish();
    }

    public void finishFromPlugin() {
        mainHandler.post(this::finishPlayer);
    }

    @Override
    protected void onDestroy() {
        stopLombotechHeartbeat();
        if (!closed) {
            finishPlayer();
        } else {
            stopPipeline();
        }
        executor.shutdownNow();
        if (currentActivity == this) currentActivity = null;
        super.onDestroy();
    }

    @Override
    public void onBackPressed() {
        finishPlayer();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) hideSystemUi();
    }

    private int dp(int value) {
        return (int) (value * getResources().getDisplayMetrics().density + 0.5f);
    }
}
