package com.andrewbal.rtspnativeplayer;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
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

import androidx.annotation.NonNull;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.rtsp.RtspMediaSource;
import androidx.media3.ui.PlayerView;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class RtspNativePlayerActivity extends Activity {
    private static RtspNativePlayerActivity currentActivity;

    private FrameLayout root;
    private PlayerView playerView;
    private ProgressBar loadingIndicator;
    private TextView statusLabel;
    private TextView titleLabel;
    private TextView cameraLabel;
    private TextView recordingIndicator;
    private Button photoButton;
    private Button recordButton;
    private Button switchButton;

    private ExoPlayer player;
    private String frontUrl;
    private String rearUrl;
    private String titleText;
    private String apiBaseUrl;
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

        if (titleText == null || titleText.length() == 0) titleText = "Live";
        if (apiBaseUrl == null || apiBaseUrl.length() == 0) apiBaseUrl = "http://192.168.0.1";

        buildUi();
        checkCameraCount();
        startPlayback(frontUrl);
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

        playerView = new PlayerView(this);
        playerView.setUseController(false);
        playerView.setResizeMode(androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_FIT);
        root.addView(playerView, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
        ));

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

        titleLabel = new TextView(this);
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

        photoButton = createRoundButton("📷", 60, Color.WHITE, Color.BLACK, 24);
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

    private void startPlayback(String url) {
        setStatus("CONNECTING", null, "Connecting...");
        showLoading(true);

        releasePlayer();

        player = new ExoPlayer.Builder(this).build();
        playerView.setPlayer(player);

        RtspMediaSource.Factory factory = new RtspMediaSource.Factory()
                .setForceUseRtpTcp(true)
                .setTimeoutMs(15000);

        MediaItem mediaItem = MediaItem.fromUri(Uri.parse(url));
        player.setMediaSource(factory.createMediaSource(mediaItem));
        player.addListener(new Player.Listener() {
            @Override
            public void onPlaybackStateChanged(int playbackState) {
                if (playbackState == Player.STATE_BUFFERING) {
                    setStatus("BUFFERING", null, "Buffering...");
                    showLoading(true);
                } else if (playbackState == Player.STATE_READY) {
                    setStatus("PLAYING", null, "");
                    showLoading(false);
                } else if (playbackState == Player.STATE_ENDED) {
                    setStatus("CLOSED", null, "Stream ended");
                }
            }

            @Override
            public void onPlayerError(@NonNull PlaybackException error) {
                showStatusText("Error: " + error.getMessage());
                RtspHlsPlayer.sendErrorToJs(error.getMessage());
            }
        });
        player.prepare();
        player.play();
    }

    private void restartPlayback(String url) {
        showLoading(true);
        mainHandler.postDelayed(() -> startPlayback(url), 500);
    }

    private void takePhoto() {
        showToast("Taking photo...");
        RtspHlsPlayer.sendActionToJs("PHOTO", currentCamera, null);

        sendCameraCommand("trigger", () -> {
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

        sendCameraCommand(start ? "start" : "stop", () -> {
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
        releasePlayer();

        String url = apiBaseUrl + "/cgi-bin/hisnet/getcamchnl.cgi?&-camid=" + camId;
        httpGet(url, response -> mainHandler.post(() -> {
            currentCamera = newCamera;
            cameraLabel.setText("front".equals(currentCamera) ? "Front" : "Rear");
            RtspHlsPlayer.sendActionToJs("CAMERA_SWITCHED", currentCamera, null);
            isSwitchingCamera = false;
            restartPlayback(frontUrl);
        }), () -> mainHandler.post(() -> {
            showToast("Failed to switch camera");
            isSwitchingCamera = false;
            restartPlayback(frontUrl);
        }));
    }

    private void checkCameraCount() {
        String url = apiBaseUrl + "/cgi-bin/hisnet/getcamnum.cgi";
        httpGet(url, response -> mainHandler.post(() -> {
            int count = parseCameraCount(response);
            setCameraCount(count >= 1 ? count : 2);
        }), () -> mainHandler.post(() -> setCameraCount(2)));
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

    private void setCameraCount(int count) {
        if (count >= 2 || (rearUrl != null && rearUrl.length() > 0)) {
            switchButton.setVisibility(View.VISIBLE);
            cameraLabel.setVisibility(View.VISIBLE);
        }
    }

    private void sendCameraCommand(String cmd, Runnable success, Runnable failure) {
        String url = apiBaseUrl + "/cgi-bin/hisnet/workmodecmd.cgi?-cmd=" + cmd;
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
        releasePlayer();
        RtspHlsPlayer.sendStatusToJs("CLOSED", null, false);
        finish();
    }

    public void finishFromPlugin() {
        mainHandler.post(this::finishPlayer);
    }

    private void releasePlayer() {
        if (player != null) {
            player.stop();
            player.release();
            player = null;
        }
        if (playerView != null) {
            playerView.setPlayer(null);
        }
    }

    @Override
    protected void onDestroy() {
        if (!closed) {
            finishPlayer();
        } else {
            releasePlayer();
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
