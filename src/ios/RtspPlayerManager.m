#import "RtspPlayerManager.h"

@interface RtspPlayerManager () <RtspClientDelegate, RtpParserDelegate, H264DecoderDelegate, PlayerViewControllerDelegate>

@property (nonatomic, strong) RtspClient *rtspClient;
@property (nonatomic, strong) RtpParser *rtpParser;
@property (nonatomic, strong) H264Decoder *decoder;
@property (nonatomic, strong) PlayerViewController *playerVC;

@property (nonatomic, copy) NSString *frontUrl;
@property (nonatomic, copy, nullable) NSString *rearUrl;
@property (nonatomic, copy, nullable) NSString *apiBaseUrl;
@property (nonatomic, copy) NSString *currentCamera;  // "front" or "rear"

// SPS/PPS from SDP (base64 decoded)
@property (nonatomic, strong, nullable) NSData *sdpSps;
@property (nonatomic, strong, nullable) NSData *sdpPps;

// SPS/PPS from in-band NAL units
@property (nonatomic, strong, nullable) NSData *inbandSps;
@property (nonatomic, strong, nullable) NSData *inbandPps;
@property (nonatomic, assign) BOOL decoderConfigured;

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
    
    NSLog(@"[PlayerManager] Starting playback: front=%@ rear=%@ api=%@", frontUrl, rearUrl, apiBaseUrl);
    
    [self.delegate playerManager:self didChangeStatus:@"STARTING" message:nil];
    
    // Create components
    _rtpParser = [RtpParser new];
    _rtpParser.delegate = self;
    
    _decoder = [H264Decoder new];
    _decoder.delegate = self;
    
    // Present player UI
    dispatch_async(dispatch_get_main_queue(), ^{
        self.playerVC = [PlayerViewController new];
        self.playerVC.delegate = self;
        self.playerVC.titleText = title;
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
#pragma mark - Internal
// ─────────────────────────────────────────────

- (void)startRtspWithUrl:(NSString *)url {
    [self.delegate playerManager:self didChangeStatus:@"CONNECTING" message:nil];
    [_playerVC setStatusText:@"Connecting to camera..."];
    
    _rtspClient = [[RtspClient alloc] initWithUrl:url];
    _rtspClient.delegate = self;
    [_rtspClient start];
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
        
        // Log first few packets to verify data flow
        if (_rtpPacketCount <= 3) {
            NSLog(@"[PlayerManager] RTP packet #%lu: %lu bytes",
                  (unsigned long)_rtpPacketCount, (unsigned long)data.length);
        } else if (_rtpPacketCount % 500 == 0) {
            NSLog(@"[PlayerManager] RTP packet #%lu (total NALs: %lu)",
                  (unsigned long)_rtpPacketCount, (unsigned long)_rtpParser.nalUnitsEmitted);
        }
        
        [_rtpParser feedRtpPacket:data];
    }
    // Ignore RTCP for now
}

- (void)rtspClient:(id)client didReceiveTrackInfo:(RtspTrackInfo *)trackInfo {
    NSLog(@"[PlayerManager] Track info received: %@", trackInfo);
    
    // Decode SPS/PPS from SDP sprop-parameter-sets
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
        
        // Try to configure decoder with SDP parameters
        if (_sdpSps && _sdpPps) {
            [self configureDecoderWithSps:_sdpSps pps:_sdpPps source:@"SDP"];
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
            // Keyframe — decode
            if (_decoderConfigured) {
                [_decoder decodeNalUnit:nalUnit timestamp:timestamp isKeyframe:YES];
            }
            break;
            
        case NalUnitTypeSlice:
            // P/B frame — decode
            if (_decoderConfigured) {
                [_decoder decodeNalUnit:nalUnit timestamp:timestamp isKeyframe:NO];
            }
            break;
            
        case NalUnitTypeSEI:
            // Ignore SEI for now
            break;
            
        default:
            break;
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
    // Enqueue decoded frame to the display layer on main thread
    CFRetain(sampleBuffer);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.playerVC enqueueSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    });
}

- (void)h264DecoderDidFailWithError:(NSString *)error {
    NSLog(@"[PlayerManager] Decoder error: %@", error);
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
    [self.delegate playerManager:self didReceiveAction:@"RECORD_TOGGLE" camera:_currentCamera data:nil];
}

- (void)playerViewControllerDidRequestCameraSwitch {
    [self.delegate playerManager:self didReceiveAction:@"CAMERA_SWITCH" camera:_currentCamera data:nil];
}

@end
