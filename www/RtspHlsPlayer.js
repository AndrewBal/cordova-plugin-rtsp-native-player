/**
 * RtspHlsPlayer - Native RTSP Player JS Bridge
 * 
 * Drop-in replacement for the FFmpegKit-based HLS player.
 * Same API surface so QuikVizn app.js works without changes.
 */

var exec = require('cordova/exec');

var RtspHlsPlayer = {
    /**
     * Start RTSP playback in a native full-screen player
     *
     * @param {object} options
     *   - frontUrl   {string}  RTSP URL for front camera
     *   - rearUrl    {string}  (optional) RTSP URL for rear camera
     *   - title      {string}  (optional) title shown in player UI
     *   - apiBaseUrl {string}  (optional) camera HTTP base URL for CGI commands
     *
     * @param {function} statusCallback  function(status, message)
     *   Statuses: STARTING, CONNECTING, PLAYING, BUFFERING, SWITCHING_CAMERA, CLOSED
     *
     * @param {function} errorCallback   function(errorString)
     *
     * @param {function} actionCallback  function(action, camera, data)
     *   Actions: PHOTO, PHOTO_SUCCESS, RECORD_START, RECORD_STOP, CAMERA_SWITCHED
     */
    play: function(options, statusCallback, errorCallback, actionCallback) {
        // Normalize options
        if (typeof options === 'string') {
            options = { frontUrl: options };
        }

        var args = [
            options.frontUrl || '',
            options.rearUrl || '',
            options.title || 'Live',
            options.apiBaseUrl || ''
        ];

        // We use a single native callback channel that dispatches to the
        // correct JS callback based on the first field of the response array.
        exec(
            function(result) {
                // result = { type: 'status'|'action', value: ..., message: ... }
                if (!result) return;

                if (result.type === 'status') {
                    if (statusCallback) statusCallback(result.value, result.message);
                } else if (result.type === 'action') {
                    if (actionCallback) actionCallback(result.value, result.camera, result.data);
                }
            },
            function(err) {
                if (errorCallback) errorCallback(err);
            },
            'RtspHlsPlayer',
            'play',
            args
        );
    },

    /**
     * Stop playback and dismiss the player
     */
    stop: function(success, error) {
        exec(success || function(){}, error || function(){}, 'RtspHlsPlayer', 'stop', []);
    }
};

module.exports = RtspHlsPlayer;
