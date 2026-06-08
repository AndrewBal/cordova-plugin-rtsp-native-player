#import "RtspPlayerManager.h"
#import "HEVCDecoder.h"

@interface RtspPlayerManager () <RtspClientDelegate, RtpParserDelegate, H264DecoderDelegate, HEVCDecoderDelegate, PlayerViewControllerDelegate>

@property (nonatomic, strong) RtspClient *rtspClient;
@property (nonatomic, strong) RtpParser *rtpParser;
@property (nonatomic, strong) H264Decoder *decoder;       // used for H.264 streams
@property (nonatomic, strong) HEVCDecoder *hevcDecoder;   // used for H.265 streams
@property (nonatomic, assign) BOOL isH265;
@property (nonatomic, strong) PlayerViewController *playerVC;

@property (nonatomic, copy) NSString *frontUrl;
@property (nonatomic, copy, nullable) NSString *rearUrl;
@property (nonatomic, copy, nullable) NSString *apiBaseUrl;
@property (nonatomic, copy) NSString *currentCamera;  // "front" or "rear"

// SPS/PPS from SDP (base64 decoded)
@property (nonatomic, strong, nullable) NSData *sdpSps;
@property (nonatomic, strong, nullable) NSData *sdpPps;

// SPS/PPS (+VPS for H.265) from in-band NAL units
@property (nonatomic, strong, nullable) NSData *inbandVps;  // H.265 only
@property (nonatomic, strong, nullable) NSData *inbandSps;
@property (nonatomic, strong, nullable) NSData *inbandPps;
// VPS/SPS/PPS from SDP for H.265
@property (nonatomic, strong, nullable) NSData *sdpVps;
@property (nonatomic, assign) BOOL decoderConfigured;

// Camera switching
@property (nonatomic, assign) BOOL isSwitchingCamera;

// Stats
@property (nonatomic, assign) NSUInteger rtpPacketCount;
@property (nonatomic, strong) NSDate *playStartTime;

@end

@implementation RtspPlayerManager

// ─────────────────────────────────────────────
#pragma mark - Public API
// ─────────────────────────────────────────────

- (void)playWithFrontUrl:(NSString *)frontUrl
                 rearUrl:(NSString *)rearUrl
                   title:(NSString *)title
              apiBaseUrl:(NSString *)apiBaseUrl
               presenter:(UIViewController *)presenter {
    
    _frontUrl = frontUrl;
    _rearUrl = rearUrl;
    _apiBaseUrl = apiBaseUrl;
    _currentCamera = @"front";
    _decoderConfigured = NO;
    _rtpPacketCount = 0;
    _isSwitchingCamera = NO;
    
    NSLog(@"[PlayerManager] Starting playback: front=%@ rear=%@ api=%@", frontUrl, rearUrl, apiBaseUrl);
    
    [self.delegate playerManager:self didChangeStatus:@"STARTING" message:nil];
    
    // Create RTP parser. Codec mode set later from SDP (didReceiveTrackInfo).
    _rtpParser = [RtpParser new];
    _rtpParser.delegate = self;

    // Decoders are created lazily after SDP tells us H.264 vs H.265.
    _isH265 = NO;
    
    // Present player UI
    dispatch_async(dispatch_get_main_queue(), ^{
        self.playerVC = [PlayerViewController new];
        self.playerVC.delegate = self;
        self.playerVC.titleText = title;
        self.playerVC.apiBaseUrl = apiBaseUrl;
        self.playerVC.currentCamera = self.currentCamera;
        self.playerVC.modalPresentationStyle = UIModalPresentationFullScreen;
        
        [presenter presentViewController:self.playerVC animated:YES completion:^{
            // Start RTSP connection after UI is visible
            [self startRtspWithUrl:frontUrl];
        }];
    });
}

- (void)stop {
    NSLog(@"[PlayerManager] Stopping playback");
    
    if (_rtspClient) {
        [_rtspClient stop];
        _rtspClient = nil;
    }
    
    [_decoder invalidate];
    [_hevcDecoder invalidate];
    [_rtpParser reset];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.playerVC) {
            [self.playerVC dismissViewControllerAnimated:YES completion:^{
                self.playerVC = nil;
            }];
        }
    });
    
    [self.delegate playerManager:self didChangeStatus:@"CLOSED" message:nil];
    
    // Log stats
    if (_playStartTime) {
        NSTimeInterval elapsed = -[_playStartTime timeIntervalSinceNow];
        NSLog(@"[PlayerManager] Session stats: %.1fs, %lu RTP packets, %lu NAL units",
              elapsed, (unsigned long)_rtpPacketCount, (unsigned long)_rtpParser.nalUnitsEmitted);
    }
}

// ─────────────────────────────────────────────
#pragma mark - Internal: RTSP
// ─────────────────────────────────────────────

- (void)startRtspWithUrl:(NSString *)url {
    [self.delegate playerManager:self didChangeStatus:@"CONNECTING" message:nil];
    [_playerVC setStatusText:@"Connecting to camera..."];
    
    _rtspClient = [[RtspClient alloc] initWithUrl:url];
    _rtspClient.delegate = self;
    [_rtspClient start];
}

/**
 * Restart RTSP connection (used after camera switch).
 * Resets decoder state to accept new SPS/PPS from the switched camera stream.
 */
- (void)restartRtspWithUrl:(NSString *)url {
    NSLog(@"[PlayerManager] Restarting RTSP with URL: %@", url);
    
    // Stop current RTSP
    if (_rtspClient) {
        [_rtspClient stop];
        _rtspClient = nil;
    }
    
    // Reset decoders/parser for new stream
    [_decoder invalidate];
    [_hevcDecoder invalidate];
    [_rtpParser reset];

    _decoderConfigured = NO;
    _sdpVps = nil;
    _sdpSps = nil;
    _sdpPps = nil;
    _inbandVps = nil;
    _inbandSps = nil;
    _inbandPps = nil;
    _rtpPacketCount = 0;
    _isH265 = NO;
    _decoder = nil;
    _hevcDecoder = nil;

    // Recreate parser (codec mode set by next SDP)
    _rtpParser = [RtpParser new];
    _rtpParser.delegate = self;
    
    // Start new connection
    [self startRtspWithUrl:url];
}

// ─────────────────────────────────────────────
#pragma mark - Camera Switching
// ─────────────────────────────────────────────

/**
 * Switch between front and rear camera.
 *
 * Hisnet cameras use getcamchnl.cgi to switch which physical camera
 * outputs to the same RTSP stream URL.
 *
 * Sequence:
 * 1. Stop current RTSP session
 * 2. Call getcamchnl.cgi?&-camid=0 (front) or getcamchnl.cgi?&-camid=1 (rear)
 * 3. Wait briefly for camera to switch
 * 4. Restart RTSP with same front URL
 */
- (void)performCameraSwitch {
    if (_isSwitchingCamera) {
        NSLog(@"[PlayerManager] Camera switch already in progress, ignoring");
        return;
    }
    _isSwitchingCamera = YES;
    
    // Toggle camera (only here — VC does NOT toggle)
    NSString *newCamera = [_currentCamera isEqualToString:@"front"] ? @"rear" : @"front";
    
    NSLog(@"[PlayerManager] Switching camera to: %@", newCamera);
    [self.delegate playerManager:self didChangeStatus:@"SWITCHING_CAMERA" message:newCamera];
    
    // Step 1: Stop current RTSP before switching hardware camera
    if (_rtspClient) {
        [_rtspClient stop];
        _rtspClient = nil;
    }
    
    // Step 2: Call getcamchnl.cgi to switch hardware camera
    NSInteger camId = [newCamera isEqualToString:@"front"] ? 0 : 1;
    NSString *urlStr = [NSString stringWithFormat:@"%@/cgi-bin/hisnet/getcamchnl.cgi?&-camid=%ld",
                        _apiBaseUrl, (long)camId];
    NSURL *url = [NSURL URLWithString:urlStr];
    
    NSLog(@"[PlayerManager] Camera switch API: %@", urlStr);
    
    // Use WiFi-only session
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 5.0;
    config.allowsCellularAccess = NO;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    
    __weak __typeof__(self) weakSelf = self;
    NSURLSessionDataTask *task = [session dataTaskWithURL:url
                                       completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong __typeof__(weakSelf) self = weakSelf;
        if (!self) return;
        
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        
        if (http.statusCode >= 200 && http.statusCode < 300 && !error) {
            NSLog(@"[PlayerManager] Camera switch API success, restarting RTSP in 500ms...");
            
            // Commit state change
            self.currentCamera = newCamera;
            
            // Update VC label
            [self.playerVC updateCameraLabel:newCamera];
            
            // Notify JS
            [self.delegate playerManager:self didReceiveAction:@"CAMERA_SWITCHED" camera:newCamera data:nil];
            
            // Step 3: Wait for hardware to switch, then restart RTSP
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                [self restartRtspWithUrl:self.frontUrl];
                self.isSwitchingCamera = NO;
            });
        } else {
            NSLog(@"[PlayerManager] Camera switch API failed: %@", error);
            
            // Revert VC UI
            [self.playerVC revertCameraSwitch];
            
            // Restart RTSP with original camera (stream was stopped)
            dispatch_async(dispatch_get_main_queue(), ^{
                [self restartRtspWithUrl:self.frontUrl];
                self.isSwitchingCamera = NO;
            });
        }
    }];
    [task resume];
}

// ─────────────────────────────────────────────
#pragma mark - RtspClientDelegate
// ─────────────────────────────────────────────

- (void)rtspClient:(id)client didChangeState:(RtspClientState)state {
    switch (state) {
        case RtspClientStateConnecting:
            [_playerVC setStatusText:@"Connecting..."];
            break;
            
        case RtspClientStatePlaying:
            _playStartTime = [NSDate date];
            [_playerVC setStatusText:@"Receiving stream..."];
            [self.delegate playerManager:self didChangeStatus:@"PLAYING" message:nil];
            break;
            
        case RtspClientStateDisconnected:
            [_playerVC setStatusText:@"Disconnected"];
            break;
            
        case RtspClientStateError:
            [_playerVC setStatusText:@"Error"];
            break;
            
        default:
            break;
    }
}

- (void)rtspClient:(id)client didReceiveRtpData:(NSData *)data channel:(uint8_t)channel {
    // Channel 0 = RTP video, Channel 1 = RTCP
    if (channel == 0) {
        _rtpPacketCount++;
        
        if (_rtpPacketCount <= 3) {
            NSLog(@"[PlayerManager] RTP packet #%lu: %lu bytes",
                  (unsigned long)_rtpPacketCount, (unsigned long)data.length);
        } else if (_rtpPacketCount % 500 == 0) {
            NSLog(@"[PlayerManager] RTP packet #%lu (total NALs: %lu)",
                  (unsigned long)_rtpPacketCount, (unsigned long)_rtpParser.nalUnitsEmitted);
        }
        
        [_rtpParser feedRtpPacket:data];
    }
}

- (void)rtspClient:(id)client didReceiveTrackInfo:(RtspTrackInfo *)trackInfo {
    NSLog(@"[PlayerManager] Track info received: %@", trackInfo);

    NSString *codec = trackInfo.codec.uppercaseString;
    _isH265 = ([codec isEqualToString:@"H265"] || [codec isEqualToString:@"HEVC"]);
    _rtpParser.isH265 = _isH265;

    if (_isH265) {
        // Create HEVC decoder
        _hevcDecoder = [HEVCDecoder new];
        _hevcDecoder.delegate = self;

        // Parse SDP sprop-vps / sprop-sps / sprop-pps (each base64 of a complete NAL)
        if (trackInfo.spropVps) _sdpVps = [[NSData alloc] initWithBase64EncodedString:trackInfo.spropVps options:0];
        if (trackInfo.spropSps) _sdpSps = [[NSData alloc] initWithBase64EncodedString:trackInfo.spropSps options:0];
        if (trackInfo.spropPps) _sdpPps = [[NSData alloc] initWithBase64EncodedString:trackInfo.spropPps options:0];

        NSLog(@"[PlayerManager] H.265 SDP VPS:%lu SPS:%lu PPS:%lu",
              (unsigned long)_sdpVps.length, (unsigned long)_sdpSps.length, (unsigned long)_sdpPps.length);

        if (_sdpVps && _sdpSps && _sdpPps) {
            [self configureHEVCDecoderWithVps:_sdpVps sps:_sdpSps pps:_sdpPps source:@"SDP"];
        }
    } else {
        // H.264 path (unchanged)
        _decoder = [H264Decoder new];
        _decoder.delegate = self;

        if (trackInfo.spropParameterSets) {
            NSArray *parts = [trackInfo.spropParameterSets componentsSeparatedByString:@","];
            if (parts.count >= 1) {
                _sdpSps = [[NSData alloc] initWithBase64EncodedString:parts[0] options:0];
                NSLog(@"[PlayerManager] SDP SPS: %lu bytes", (unsigned long)_sdpSps.length);
            }
            if (parts.count >= 2) {
                _sdpPps = [[NSData alloc] initWithBase64EncodedString:parts[1] options:0];
                NSLog(@"[PlayerManager] SDP PPS: %lu bytes", (unsigned long)_sdpPps.length);
            }
            if (_sdpSps && _sdpPps) {
                [self configureDecoderWithSps:_sdpSps pps:_sdpPps source:@"SDP"];
            }
        }
    }
}

- (void)rtspClient:(id)client didFailWithError:(NSString *)error {
    NSLog(@"[PlayerManager] RTSP error: %@", error);
    [_playerVC setStatusText:[NSString stringWithFormat:@"Error: %@", error]];
    [self.delegate playerManager:self didFailWithError:error];
}

// ─────────────────────────────────────────────
#pragma mark - RtpParserDelegate
// ─────────────────────────────────────────────

- (void)rtpParserDidReceiveNalUnit:(NSData *)nalUnit type:(NalUnitType)type timestamp:(uint32_t)timestamp {
    if (_isH265) {
        [self handleH265NalUnit:nalUnit type:(uint8_t)type timestamp:timestamp];
    } else {
        [self handleH264NalUnit:nalUnit type:type timestamp:timestamp];
    }
}

- (void)handleH264NalUnit:(NSData *)nalUnit type:(NalUnitType)type timestamp:(uint32_t)timestamp {
    switch (type) {
        case NalUnitTypeSPS:
            _inbandSps = nalUnit;
            if (_inbandPps && !_decoderConfigured) {
                [self configureDecoderWithSps:_inbandSps pps:_inbandPps source:@"in-band"];
            }
            break;
        case NalUnitTypePPS:
            _inbandPps = nalUnit;
            if (_inbandSps && !_decoderConfigured) {
                [self configureDecoderWithSps:_inbandSps pps:_inbandPps source:@"in-band"];
            }
            break;
        case NalUnitTypeIDR:
            if (_decoderConfigured) [_decoder decodeNalUnit:nalUnit timestamp:timestamp isKeyframe:YES];
            break;
        case NalUnitTypeSlice:
            if (_decoderConfigured) [_decoder decodeNalUnit:nalUnit timestamp:timestamp isKeyframe:NO];
            break;
        case NalUnitTypeSEI:
        default:
            break;
    }
}

- (void)handleH265NalUnit:(NSData *)nalUnit type:(uint8_t)type timestamp:(uint32_t)timestamp {
    switch (type) {
        case 32:  // VPS_NUT
            _inbandVps = nalUnit;
            if (_inbandSps && _inbandPps && !_decoderConfigured) {
                [self configureHEVCDecoderWithVps:_inbandVps sps:_inbandSps pps:_inbandPps source:@"in-band"];
            }
            break;
        case 33:  // SPS_NUT
            _inbandSps = nalUnit;
            if (_inbandVps && _inbandPps && !_decoderConfigured) {
                [self configureHEVCDecoderWithVps:_inbandVps sps:_inbandSps pps:_inbandPps source:@"in-band"];
            }
            break;
        case 34:  // PPS_NUT
            _inbandPps = nalUnit;
            if (_inbandVps && _inbandSps && !_decoderConfigured) {
                [self configureHEVCDecoderWithVps:_inbandVps sps:_inbandSps pps:_inbandPps source:@"in-band"];
            }
            break;
        case 19:  // IDR_W_RADL
        case 20:  // IDR_N_LP
        case 21:  // CRA_NUT — also keyframe for decoding purposes
            if (_decoderConfigured) [_hevcDecoder decodeNalUnit:nalUnit timestamp:timestamp isKeyframe:YES];
            break;
        case 39:  // PREFIX_SEI
        case 40:  // SUFFIX_SEI
            break;
        default:
            // VCL trail/etc. — treat as non-key slice
            if (type <= 31 && _decoderConfigured) {
                [_hevcDecoder decodeNalUnit:nalUnit timestamp:timestamp isKeyframe:NO];
            }
            break;
    }
}

- (void)configureHEVCDecoderWithVps:(NSData *)vps sps:(NSData *)sps pps:(NSData *)pps source:(NSString *)source {
    NSLog(@"[PlayerManager] Configuring HEVC decoder with %@ VPS(%lu) SPS(%lu) PPS(%lu)",
          source, (unsigned long)vps.length, (unsigned long)sps.length, (unsigned long)pps.length);
    BOOL ok = [_hevcDecoder configureWithVps:vps sps:sps pps:pps];
    if (ok) {
        _decoderConfigured = YES;
        NSLog(@"[PlayerManager] HEVC decoder configured ✓");
    } else {
        NSLog(@"[PlayerManager] HEVC decoder configuration failed!");
    }
}

// ─────────────────────────────────────────────
#pragma mark - Decoder configuration
// ─────────────────────────────────────────────

- (void)configureDecoderWithSps:(NSData *)sps pps:(NSData *)pps source:(NSString *)source {
    NSLog(@"[PlayerManager] Configuring decoder with %@ SPS(%lu) PPS(%lu)",
          source, (unsigned long)sps.length, (unsigned long)pps.length);
    
    BOOL ok = [_decoder configureWithSps:sps pps:pps];
    if (ok) {
        _decoderConfigured = YES;
        NSLog(@"[PlayerManager] Decoder configured ✓");
    } else {
        NSLog(@"[PlayerManager] Decoder configuration failed!");
    }
}

// ─────────────────────────────────────────────
#pragma mark - H264DecoderDelegate
// ─────────────────────────────────────────────

- (void)h264DecoderDidDecodeFrame:(CMSampleBufferRef)sampleBuffer {
    CFRetain(sampleBuffer);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.playerVC enqueueSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    });
}

- (void)h264DecoderDidFailWithError:(NSString *)error {
    NSLog(@"[PlayerManager] H.264 decoder error: %@", error);
}

// ─────────────────────────────────────────────
#pragma mark - HEVCDecoderDelegate
// ─────────────────────────────────────────────

- (void)hevcDecoderDidDecodeFrame:(CMSampleBufferRef)sampleBuffer {
    CFRetain(sampleBuffer);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.playerVC enqueueSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    });
}

- (void)hevcDecoderDidFailWithError:(NSString *)error {
    NSLog(@"[PlayerManager] HEVC decoder error: %@", error);
}

// ─────────────────────────────────────────────
#pragma mark - PlayerViewControllerDelegate
// ─────────────────────────────────────────────

- (void)playerViewControllerDidClose {
    [self stop];
}

- (void)playerViewControllerDidRequestPhoto {
    [self.delegate playerManager:self didReceiveAction:@"PHOTO" camera:_currentCamera data:nil];
}

- (void)playerViewControllerDidRequestRecordToggle {
    // The VC already sends the HTTP command and updates its own UI.
    // Forward action notification to JS.
    [self.delegate playerManager:self didReceiveAction:@"RECORD_TOGGLE" camera:_currentCamera data:nil];
}

- (void)playerViewControllerDidRequestCameraSwitch {
    [self performCameraSwitch];
}

@end
