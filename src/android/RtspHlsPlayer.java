package com.andrewbal.rtspnativeplayer;

import android.content.Intent;
import android.os.Bundle;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

public class RtspHlsPlayer extends CordovaPlugin {
    private static RtspHlsPlayer instance;
    private CallbackContext playCallback;

    @Override
    protected void pluginInitialize() {
        instance = this;
    }

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext callbackContext) throws JSONException {
        if ("play".equals(action)) {
            play(args, callbackContext);
            return true;
        }

        if ("stop".equals(action)) {
            stop(callbackContext);
            return true;
        }

        return false;
    }

    private void play(JSONArray args, CallbackContext callbackContext) {
        String frontUrl = args.optString(0, "");
        String rearUrl = args.optString(1, "");
        String title = args.optString(2, "Live");
        String apiBaseUrl = args.optString(3, "");

        boolean forceVlc = args.optBoolean(4, false);
        String deviceType = args.optString(5, "");

        if (frontUrl == null || frontUrl.trim().length() == 0) {
            callbackContext.error("frontUrl is required");
            return;
        }

        playCallback = callbackContext;

        Intent intent = new Intent(cordova.getActivity(), RtspNativePlayerActivity.class);
        intent.putExtra("frontUrl", frontUrl);
        intent.putExtra("rearUrl", rearUrl == null ? "" : rearUrl);
        intent.putExtra("title", title == null || title.length() == 0 ? "Live" : title);
        intent.putExtra("apiBaseUrl", apiBaseUrl == null ? "" : apiBaseUrl);
        intent.putExtra("forceVlc", forceVlc);
        intent.putExtra("deviceType", deviceType == null ? "" : deviceType);

        cordova.getActivity().startActivity(intent);
        sendStatus("STARTING", null, true);
    }

    private void stop(CallbackContext callbackContext) {
        RtspNativePlayerActivity activity = RtspNativePlayerActivity.getCurrentActivity();
        if (activity != null) {
            activity.finishFromPlugin();
        }

        PluginResult result = new PluginResult(PluginResult.Status.OK);
        callbackContext.sendPluginResult(result);
    }

    public static void sendStatusToJs(String status, String message, boolean keepCallback) {
        RtspHlsPlayer plugin = instance;
        if (plugin != null) {
            plugin.sendStatus(status, message, keepCallback);
        }
    }

    public static void sendActionToJs(String action, String camera, JSONObject data) {
        RtspHlsPlayer plugin = instance;
        if (plugin != null) {
            plugin.sendAction(action, camera, data);
        }
    }

    public static void sendErrorToJs(String error) {
        RtspHlsPlayer plugin = instance;
        if (plugin != null) {
            plugin.sendError(error);
        }
    }

    private void sendStatus(String status, String message, boolean keepCallback) {
        if (playCallback == null) return;

        try {
            JSONObject payload = new JSONObject();
            payload.put("type", "status");
            payload.put("value", status);
            payload.put("message", message == null ? JSONObject.NULL : message);

            PluginResult result = new PluginResult(PluginResult.Status.OK, payload);
            result.setKeepCallback(keepCallback);
            playCallback.sendPluginResult(result);

            if (!keepCallback) {
                playCallback = null;
            }
        } catch (JSONException e) {
            sendError(e.getMessage());
        }
    }

    private void sendAction(String action, String camera, JSONObject data) {
        if (playCallback == null) return;

        try {
            JSONObject payload = new JSONObject();
            payload.put("type", "action");
            payload.put("value", action);
            if (camera != null) payload.put("camera", camera);
            if (data != null) payload.put("data", data);

            PluginResult result = new PluginResult(PluginResult.Status.OK, payload);
            result.setKeepCallback(true);
            playCallback.sendPluginResult(result);
        } catch (JSONException e) {
            sendError(e.getMessage());
        }
    }

    private void sendError(String error) {
        if (playCallback == null) return;

        PluginResult result = new PluginResult(PluginResult.Status.ERROR, error == null ? "Unknown error" : error);
        result.setKeepCallback(false);
        playCallback.sendPluginResult(result);
        playCallback = null;
    }

    @Override
    public void onReset() {
        playCallback = null;
        super.onReset();
    }

    @Override
    public void onDestroy() {
        if (instance == this) {
            instance = null;
        }
        playCallback = null;
        super.onDestroy();
    }
}
