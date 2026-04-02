#import "RtspClient.h"

// ─────────────────────────────────────────────────────
#pragma mark - RtspTrackInfo
// ─────────────────────────────────────────────────────

@implementation RtspTrackInfo
- (NSString *)description {
    return [NSString stringWithFormat:@"<Track codec=%@ pt=%d clock=%d control=%@ sprop=%@>",
            _codec, _payloadType, _clockRate, _controlUrl, _spropParameterSets];
}
@end

// ─────────────────────────────────────────────────────
#pragma mark - RtspClient private
// ─────────────────────────────────────────────────────

@interface RtspClient ()

// Connection
@property (nonatomic, strong) nw_connection_t connection;
@property (nonatomic, strong) dispatch_queue_t queue;

// RTSP state
@property (nonatomic, readwrite) RtspClientState state;
@property (nonatomic, assign) int cseq;
@property (nonatomic, copy) NSString *sessionId;
@property (nonatomic, strong) RtspTrackInfo *videoTrack;

// URL components
@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, copy) NSString *path;            // e.g. /livestream/1
@property (nonatomic, readwrite, copy) NSString *rtspUrl;

// Read buffer for accumulating TCP data
@property (nonatomic, strong) NSMutableData *readBuffer;

// Keepalive timer
@property (nonatomic, strong) dispatch_source_t keepaliveTimer;

// Flag to prevent double-stop
@property (nonatomic, assign) BOOL stopped;

@end

// ─────────────────────────────────────────────────────
#pragma mark - Implementation
// ─────────────────────────────────────────────────────

@implementation RtspClient

- (instancetype)initWithUrl:(NSString *)rtspUrl {
    self = [super init];
    if (self) {
        _rtspUrl = [rtspUrl copy];
        _state = RtspClientStateDisconnected;
        _cseq = 0;
        _keepaliveInterval = 3.0;
        _readBuffer = [NSMutableData new];
        _stopped = NO;
        _queue = dispatch_queue_create("com.quikvizn.rtsp.client", DISPATCH_QUEUE_SERIAL);
        
        [self parseUrl:rtspUrl];
    }
    return self;
}

- (void)dealloc {
    // Don't call [self stop] — it dispatches async, which is unsafe during dealloc
    // (the block captures self, but the object is already being destroyed → EXC_BAD_ACCESS)
    // Do synchronous cleanup instead:
    if (_keepaliveTimer) {
        dispatch_source_cancel(_keepaliveTimer);
        _keepaliveTimer = nil;
    }
    if (_connection) {
        nw_connection_cancel(_connection);
        _connection = nil;
    }
    _stopped = YES;
}

// ─────────────────────────────────────────────────────
#pragma mark - URL parsing
// ─────────────────────────────────────────────────────

- (void)parseUrl:(NSString *)urlStr {
    // rtsp://192.168.0.1:554/livestream/1
    // We can't use NSURL for rtsp scheme reliably, parse manually
    NSString *stripped = urlStr;
    if ([stripped hasPrefix:@"rtsp://"]) {
        stripped = [stripped substringFromIndex:7];
    }
    
    // Split host:port/path
    NSRange slashRange = [stripped rangeOfString:@"/"];
    NSString *hostPort;
    if (slashRange.location != NSNotFound) {
        hostPort = [stripped substringToIndex:slashRange.location];
        _path = [stripped substringFromIndex:slashRange.location];
    } else {
        hostPort = stripped;
        _path = @"/";
    }
    
    NSRange colonRange = [hostPort rangeOfString:@":"];
    if (colonRange.location != NSNotFound) {
        _host = [hostPort substringToIndex:colonRange.location];
        _port = (uint16_t)[[hostPort substringFromIndex:colonRange.location + 1] intValue];
    } else {
        _host = hostPort;
        _port = 554;
    }
    
    NSLog(@"[RtspClient] Parsed URL: host=%@ port=%d path=%@", _host, _port, _path);
}

// ─────────────────────────────────────────────────────
#pragma mark - Public: start / stop
// ─────────────────────────────────────────────────────

- (void)start {
    dispatch_async(_queue, ^{
        self.stopped = NO;
        [self setState:RtspClientStateConnecting];
        [self connectTcp];
    });
}

- (void)stop {
    dispatch_async(_queue, ^{
        if (self.stopped) return;
        self.stopped = YES;
        
        [self stopKeepalive];
        
        // Try sending TEARDOWN if we have a session
        if (self.sessionId && self.connection) {
            [self setState:RtspClientStateTeardown];
            NSString *req = [self buildRequest:@"TEARDOWN" extraHeaders:
                             [NSString stringWithFormat:@"Session: %@\r\n", self.sessionId]];
            NSData *data = [req dataUsingEncoding:NSUTF8StringEncoding];
            nw_connection_send(self.connection, 
                              dispatch_data_create(data.bytes, data.length, self.queue, DISPATCH_DATA_DESTRUCTOR_DEFAULT),
                              NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t _Nullable error) {
                // Don't care about result
            });
        }
        
        if (self.connection) {
            nw_connection_cancel(self.connection);
            self.connection = nil;
        }
        
        [self setState:RtspClientStateDisconnected];
    });
}

// ─────────────────────────────────────────────────────
#pragma mark - NWConnection TCP
// ─────────────────────────────────────────────────────

- (void)connectTcp {
    NSLog(@"[RtspClient] Connecting TCP to %@:%d (WiFi-bound)", _host, _port);
    
    // Create TCP parameters
    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL,   // no TLS
        NW_PARAMETERS_DEFAULT_CONFIGURATION // default TCP
    );
    
    // CRITICAL: find the WiFi interface and bind to it,
    // so iOS doesn't route the TCP connection through cellular.
    // nw_parameters_require_interface_type() doesn't exist in the C API,
    // so we discover the WiFi interface via path monitor and use
    // nw_parameters_require_interface() instead.
    
    __weak __typeof__(self) weakSelf = self;
    
    nw_path_monitor_t monitor = nw_path_monitor_create_with_type(nw_interface_type_wifi);
    nw_path_monitor_set_queue(monitor, _queue);
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        __strong __typeof__(weakSelf) self = weakSelf;
        if (!self || self.stopped) {
            nw_path_monitor_cancel(monitor);
            return;
        }
        
        // We only need the first update — cancel immediately
        nw_path_monitor_cancel(monitor);
        
        // Find a WiFi interface from the path
        __block nw_interface_t wifiIface = nil;
        nw_path_enumerate_interfaces(path, ^bool(nw_interface_t iface) {
            if (nw_interface_get_type(iface) == nw_interface_type_wifi) {
                wifiIface = iface;
                return false;  // stop enumeration
            }
            return true;
        });
        
        if (wifiIface) {
            nw_parameters_require_interface(params, wifiIface);
            NSLog(@"[RtspClient] Bound to WiFi interface: %s ✓", nw_interface_get_name(wifiIface));
        } else {
            NSLog(@"[RtspClient] WARNING: No WiFi interface found, connection may go through cellular");
        }
        
        // Now create and start the connection
        [self startConnectionWithParams:params];
    });
    
    nw_path_monitor_start(monitor);
}

/**
 * Create NWConnection with the given parameters and start it.
 * Called after WiFi interface has been resolved.
 */
- (void)startConnectionWithParams:(nw_parameters_t)params {
    nw_endpoint_t endpoint = nw_endpoint_create_host(
        [_host UTF8String],
        [[NSString stringWithFormat:@"%d", _port] UTF8String]
    );
    
    _connection = nw_connection_create(endpoint, params);
    nw_connection_set_queue(_connection, _queue);
    
    __weak __typeof__(self) weakSelf = self;
    
    nw_connection_set_state_changed_handler(_connection, ^(nw_connection_state_t nwState, nw_error_t _Nullable error) {
        __strong __typeof__(weakSelf) self = weakSelf;
        if (!self || self.stopped) return;
        
        switch (nwState) {
            case nw_connection_state_ready:
                NSLog(@"[RtspClient] TCP connected ✓");
                [self sendOptions];
                break;
                
            case nw_connection_state_failed: {
                NSString *errMsg = @"TCP connection failed";
                if (error) {
                    errMsg = [NSString stringWithFormat:@"TCP failed: %s", 
                              nw_error_get_error_domain(error) == nw_error_domain_posix 
                              ? strerror(nw_error_get_error_code(error))
                              : "network error"];
                }
                NSLog(@"[RtspClient] %@", errMsg);
                [self setState:RtspClientStateError];
                [self.delegate rtspClient:self didFailWithError:errMsg];
                break;
            }
                
            case nw_connection_state_cancelled:
                NSLog(@"[RtspClient] TCP cancelled");
                break;
                
            case nw_connection_state_waiting: {
                NSString *errMsg = @"TCP waiting (no WiFi route?)";
                if (error) {
                    errMsg = [NSString stringWithFormat:@"TCP waiting: %s",
                              nw_error_get_error_domain(error) == nw_error_domain_posix
                              ? strerror(nw_error_get_error_code(error))
                              : "network error"];
                }
                NSLog(@"[RtspClient] %@", errMsg);
                break;
            }
                
            default:
                break;
        }
    });
    
    nw_connection_start(_connection);
}

// ─────────────────────────────────────────────────────
#pragma mark - RTSP request building
// ─────────────────────────────────────────────────────

- (NSString *)buildRequest:(NSString *)method extraHeaders:(NSString * _Nullable)extra {
    _cseq++;
    NSMutableString *req = [NSMutableString new];
    [req appendFormat:@"%@ %@ RTSP/1.0\r\n", method, _rtspUrl];
    [req appendFormat:@"CSeq: %d\r\n", _cseq];
    [req appendString:@"User-Agent: QuikVizn/1.0\r\n"];
    if (extra) {
        [req appendString:extra];
    }
    [req appendString:@"\r\n"];
    return req;
}

- (NSString *)buildRequestForUrl:(NSString *)url method:(NSString *)method extraHeaders:(NSString * _Nullable)extra {
    _cseq++;
    NSMutableString *req = [NSMutableString new];
    [req appendFormat:@"%@ %@ RTSP/1.0\r\n", method, url];
    [req appendFormat:@"CSeq: %d\r\n", _cseq];
    [req appendString:@"User-Agent: QuikVizn/1.0\r\n"];
    if (extra) {
        [req appendString:extra];
    }
    [req appendString:@"\r\n"];
    return req;
}

// ─────────────────────────────────────────────────────
#pragma mark - Send / Receive helpers
// ─────────────────────────────────────────────────────

- (void)sendRtspRequest:(NSString *)request {
    if (!_connection || _stopped) return;
    
    NSLog(@"[RtspClient] >>> SEND:\n%@", request);
    
    NSData *data = [request dataUsingEncoding:NSUTF8StringEncoding];
    dispatch_data_t dispatchData = dispatch_data_create(data.bytes, data.length, _queue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    
    __weak __typeof__(self) weakSelf = self;
    nw_connection_send(_connection, dispatchData, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false,
                       ^(nw_error_t _Nullable error) {
        if (error) {
            __strong __typeof__(weakSelf) self = weakSelf;
            NSLog(@"[RtspClient] Send error");
            if (self && !self.stopped) {
                [self setState:RtspClientStateError];
                [self.delegate rtspClient:self didFailWithError:@"RTSP send failed"];
            }
        }
    });
}

/**
 * Read RTSP text response (ends with \r\n\r\n, possibly followed by body).
 * After PLAY, the stream switches to binary interleaved mode.
 */
- (void)readRtspResponse:(void (^)(NSString *response))completion {
    if (!_connection || _stopped) return;
    
    __weak __typeof__(self) weakSelf = self;
    
    // Read a chunk of data
    nw_connection_receive(_connection, 1, 65536, ^(dispatch_data_t _Nullable content,
                                                    nw_content_context_t _Nullable context,
                                                    bool isComplete,
                                                    nw_error_t _Nullable error) {
        __strong __typeof__(weakSelf) self = weakSelf;
        if (!self || self.stopped) return;
        
        if (error) {
            NSLog(@"[RtspClient] Read error");
            [self setState:RtspClientStateError];
            [self.delegate rtspClient:self didFailWithError:@"RTSP read failed"];
            return;
        }
        
        if (content) {
            // Append to read buffer
            dispatch_data_apply(content, ^bool(dispatch_data_t  _Nonnull region, size_t offset, const void * _Nonnull buffer, size_t size) {
                [self.readBuffer appendBytes:buffer length:size];
                return true;
            });
        }
        
        // Check if we have a complete RTSP response
        NSString *bufferStr = [[NSString alloc] initWithData:self.readBuffer encoding:NSUTF8StringEncoding];
        if (!bufferStr) {
            // Binary data arrived (shouldn't happen before PLAY), keep reading
            [self readRtspResponse:completion];
            return;
        }
        
        NSRange headerEnd = [bufferStr rangeOfString:@"\r\n\r\n"];
        if (headerEnd.location == NSNotFound) {
            // Incomplete response, keep reading
            [self readRtspResponse:completion];
            return;
        }
        
        // Check for Content-Length to read body
        NSString *headers = [bufferStr substringToIndex:headerEnd.location];
        NSInteger contentLength = 0;
        NSRegularExpression *clRegex = [NSRegularExpression regularExpressionWithPattern:@"Content-[Ll]ength:\\s*(\\d+)"
                                                                                options:0 error:nil];
        NSTextCheckingResult *clMatch = [clRegex firstMatchInString:headers options:0
                                                              range:NSMakeRange(0, headers.length)];
        if (clMatch) {
            contentLength = [[headers substringWithRange:[clMatch rangeAtIndex:1]] integerValue];
        }
        
        NSInteger totalNeeded = headerEnd.location + 4 + contentLength;
        
        if ((NSInteger)self.readBuffer.length < totalNeeded) {
            // Need more data for body
            [self readRtspResponse:completion];
            return;
        }
        
        // Extract full response
        NSData *responseData = [self.readBuffer subdataWithRange:NSMakeRange(0, totalNeeded)];
        NSString *response = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
        
        // Remove consumed data from buffer (keep any leftover for interleaved frames)
        NSData *remaining = nil;
        if ((NSInteger)self.readBuffer.length > totalNeeded) {
            remaining = [self.readBuffer subdataWithRange:NSMakeRange(totalNeeded, self.readBuffer.length - totalNeeded)];
        }
        [self.readBuffer setLength:0];
        if (remaining) {
            [self.readBuffer appendData:remaining];
        }
        
        NSLog(@"[RtspClient] <<< RECV (%lu bytes, %lu leftover):\n%@",
              (unsigned long)responseData.length,
              (unsigned long)self.readBuffer.length,
              response);
        
        completion(response);
    });
}

// ─────────────────────────────────────────────────────
#pragma mark - RTSP State Machine
// ─────────────────────────────────────────────────────

- (void)sendOptions {
    [self setState:RtspClientStateOptions];
    NSString *req = [self buildRequest:@"OPTIONS" extraHeaders:nil];
    [self sendRtspRequest:req];
    
    __weak __typeof__(self) weakSelf = self;
    [self readRtspResponse:^(NSString *response) {
        __strong __typeof__(weakSelf) self = weakSelf;
        if (!self || self.stopped) return;
        
        if ([self parseStatusCode:response] != 200) {
            [self failWithError:@"OPTIONS failed" response:response];
            return;
        }
        
        NSLog(@"[RtspClient] OPTIONS OK ✓");
        [self sendDescribe];
    }];
}

- (void)sendDescribe {
    [self setState:RtspClientStateDescribe];
    NSString *req = [self buildRequest:@"DESCRIBE" extraHeaders:@"Accept: application/sdp\r\n"];
    [self sendRtspRequest:req];
    
    __weak __typeof__(self) weakSelf = self;
    [self readRtspResponse:^(NSString *response) {
        __strong __typeof__(weakSelf) self = weakSelf;
        if (!self || self.stopped) return;
        
        if ([self parseStatusCode:response] != 200) {
            [self failWithError:@"DESCRIBE failed" response:response];
            return;
        }
        
        NSLog(@"[RtspClient] DESCRIBE OK ✓");
        
        // Parse SDP
        RtspTrackInfo *track = [self parseSdp:response];
        if (!track) {
            [self failWithError:@"No H.264 video track in SDP" response:response];
            return;
        }
        
        self.videoTrack = track;
        NSLog(@"[RtspClient] Video track: %@", track);
        
        // Notify delegate about track info (for decoder setup)
        [self.delegate rtspClient:self didReceiveTrackInfo:track];
        
        [self sendSetup];
    }];
}

- (void)sendSetup {
    [self setState:RtspClientStateSetup];
    
    // Build SETUP URL: base + / + control
    NSString *setupUrl;
    NSString *control = self.videoTrack.controlUrl ?: @"trackID=0";
    if ([control hasPrefix:@"rtsp://"]) {
        setupUrl = control;  // absolute control URL
    } else {
        setupUrl = [NSString stringWithFormat:@"%@/%@", _rtspUrl, control];
    }
    
    NSString *req = [self buildRequestForUrl:setupUrl
                                     method:@"SETUP"
                               extraHeaders:@"Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n"];
    [self sendRtspRequest:req];
    
    __weak __typeof__(self) weakSelf = self;
    [self readRtspResponse:^(NSString *response) {
        __strong __typeof__(weakSelf) self = weakSelf;
        if (!self || self.stopped) return;
        
        if ([self parseStatusCode:response] != 200) {
            [self failWithError:@"SETUP failed" response:response];
            return;
        }
        
        // Extract Session ID
        NSRegularExpression *sessRegex = [NSRegularExpression regularExpressionWithPattern:@"Session:\\s*([^;\\r\\n]+)"
                                                                                  options:0 error:nil];
        NSTextCheckingResult *sessMatch = [sessRegex firstMatchInString:response options:0
                                                                  range:NSMakeRange(0, response.length)];
        if (sessMatch) {
            self.sessionId = [[response substringWithRange:[sessMatch rangeAtIndex:1]]
                              stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
        
        NSLog(@"[RtspClient] SETUP OK ✓ session=%@", self.sessionId);
        
        [self sendPlay];
    }];
}

- (void)sendPlay {
    NSString *sessionHeader = self.sessionId 
        ? [NSString stringWithFormat:@"Session: %@\r\nRange: npt=0.000-\r\n", self.sessionId]
        : @"Range: npt=0.000-\r\n";
    
    NSString *req = [self buildRequest:@"PLAY" extraHeaders:sessionHeader];
    [self sendRtspRequest:req];
    
    __weak __typeof__(self) weakSelf = self;
    [self readRtspResponse:^(NSString *response) {
        __strong __typeof__(weakSelf) self = weakSelf;
        if (!self || self.stopped) return;
        
        if ([self parseStatusCode:response] != 200) {
            [self failWithError:@"PLAY failed" response:response];
            return;
        }
        
        NSLog(@"[RtspClient] PLAY OK ✓ — RTSP handshake complete, entering RTP receive mode");
        [self setState:RtspClientStatePlaying];
        
        // Start keepalive timer
        [self startKeepalive];
        
        // Process any leftover data in readBuffer as interleaved frames
        if (self.readBuffer.length > 0) {
            NSLog(@"[RtspClient] Processing %lu bytes of leftover data", (unsigned long)self.readBuffer.length);
            [self processInterleavedData];
        }
        
        // Start continuous read loop for interleaved RTP data
        [self readInterleavedLoop];
    }];
}

// ─────────────────────────────────────────────────────
#pragma mark - TCP Interleaved RTP reader
// ─────────────────────────────────────────────────────

/**
 * Continuously read TCP data and extract interleaved RTP frames.
 *
 * Format: $ (0x24) | channel (1 byte) | length (2 bytes BE) | payload (length bytes)
 * Channel 0 = RTP video, Channel 1 = RTCP video
 */
- (void)readInterleavedLoop {
    if (!_connection || _stopped) return;
    
    __weak __typeof__(self) weakSelf = self;
    
    nw_connection_receive(_connection, 1, 65536, ^(dispatch_data_t _Nullable content,
                                                    nw_content_context_t _Nullable context,
                                                    bool isComplete,
                                                    nw_error_t _Nullable error) {
        __strong __typeof__(weakSelf) self = weakSelf;
        if (!self || self.stopped) return;
        
        if (error) {
            NSLog(@"[RtspClient] Interleaved read error");
            [self setState:RtspClientStateError];
            [self.delegate rtspClient:self didFailWithError:@"Stream read failed"];
            return;
        }
        
        if (content) {
            dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
                [self.readBuffer appendBytes:buffer length:size];
                return true;
            });
            
            [self processInterleavedData];
        }
        
        if (isComplete) {
            NSLog(@"[RtspClient] Stream ended (isComplete)");
            [self setState:RtspClientStateDisconnected];
            [self.delegate rtspClient:self didFailWithError:@"Stream ended"];
            return;
        }
        
        // Continue reading
        [self readInterleavedLoop];
    });
}

/**
 * Process accumulated data in readBuffer, extracting complete interleaved frames.
 */
- (void)processInterleavedData {
    const uint8_t *bytes = (const uint8_t *)_readBuffer.bytes;
    NSUInteger length = _readBuffer.length;
    NSUInteger offset = 0;
    
    while (offset < length) {
        // Need at least 4 bytes for the interleaved header
        if (length - offset < 4) break;
        
        // Check for $ magic byte
        if (bytes[offset] != 0x24) {
            // Might be an RTSP response mixed in (e.g. keepalive reply)
            // Scan for next $ or end of buffer
            NSUInteger scanStart = offset;
            while (offset < length && bytes[offset] != 0x24) {
                offset++;
            }
            // Log the skipped data (likely an RTSP response to GET_PARAMETER)
            if (offset > scanStart) {
                NSData *skipped = [NSData dataWithBytes:bytes + scanStart length:offset - scanStart];
                NSString *skippedStr = [[NSString alloc] initWithData:skipped encoding:NSUTF8StringEncoding];
                if (skippedStr) {
                    NSLog(@"[RtspClient] Skipped non-interleaved data (%lu bytes): %.80s...", 
                          (unsigned long)(offset - scanStart), [skippedStr UTF8String]);
                }
            }
            continue;
        }
        
        uint8_t channel = bytes[offset + 1];
        uint16_t frameLen = ((uint16_t)bytes[offset + 2] << 8) | bytes[offset + 3];
        
        // Sanity check
        if (frameLen > 65535 || frameLen == 0) {
            NSLog(@"[RtspClient] Invalid interleaved frame length: %d, skipping byte", frameLen);
            offset++;
            continue;
        }
        
        // Check if we have the full frame
        if (length - offset < 4 + (NSUInteger)frameLen) {
            break;  // Wait for more data
        }
        
        // Extract RTP payload
        NSData *rtpData = [NSData dataWithBytes:bytes + offset + 4 length:frameLen];
        offset += 4 + frameLen;
        
        // Deliver to delegate
        [self.delegate rtspClient:self didReceiveRtpData:rtpData channel:channel];
    }
    
    // Remove consumed data from buffer
    if (offset > 0) {
        if (offset >= _readBuffer.length) {
            [_readBuffer setLength:0];
        } else {
            NSData *remaining = [_readBuffer subdataWithRange:NSMakeRange(offset, _readBuffer.length - offset)];
            [_readBuffer setLength:0];
            [_readBuffer appendData:remaining];
        }
    }
}

// ─────────────────────────────────────────────────────
#pragma mark - Keepalive
// ─────────────────────────────────────────────────────

- (void)startKeepalive {
    [self stopKeepalive];
    
    __weak __typeof__(self) weakSelf = self;
    _keepaliveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    
    uint64_t interval = (uint64_t)(_keepaliveInterval * NSEC_PER_SEC);
    dispatch_source_set_timer(_keepaliveTimer, 
                              dispatch_time(DISPATCH_TIME_NOW, interval),
                              interval, 
                              NSEC_PER_SEC / 10);
    
    dispatch_source_set_event_handler(_keepaliveTimer, ^{
        __strong __typeof__(weakSelf) self = weakSelf;
        if (!self || self.stopped || !self.connection) return;
        
        // Send GET_PARAMETER as keepalive (camera expects every ~3s)
        NSString *sessionHeader = self.sessionId
            ? [NSString stringWithFormat:@"Session: %@\r\n", self.sessionId]
            : @"";
        NSString *req = [self buildRequest:@"GET_PARAMETER" extraHeaders:sessionHeader];
        NSData *data = [req dataUsingEncoding:NSUTF8StringEncoding];
        dispatch_data_t dispatchData = dispatch_data_create(data.bytes, data.length, self.queue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        
        nw_connection_send(self.connection, dispatchData, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false,
                           ^(nw_error_t _Nullable error) {
            if (error) {
                NSLog(@"[RtspClient] Keepalive send failed");
            }
        });
    });
    
    dispatch_resume(_keepaliveTimer);
    NSLog(@"[RtspClient] Keepalive started (%.1fs interval)", _keepaliveInterval);
}

- (void)stopKeepalive {
    if (_keepaliveTimer) {
        dispatch_source_cancel(_keepaliveTimer);
        _keepaliveTimer = nil;
    }
}

// ─────────────────────────────────────────────────────
#pragma mark - RTSP Response parsing
// ─────────────────────────────────────────────────────

- (int)parseStatusCode:(NSString *)response {
    // RTSP/1.0 200 OK
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"RTSP/1\\.0\\s+(\\d+)"
                                                                          options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:response options:0
                                                      range:NSMakeRange(0, MIN(response.length, 100))];
    if (match) {
        return [[response substringWithRange:[match rangeAtIndex:1]] intValue];
    }
    return -1;
}

// ─────────────────────────────────────────────────────
#pragma mark - SDP parsing
// ─────────────────────────────────────────────────────

- (RtspTrackInfo *)parseSdp:(NSString *)response {
    // Find SDP body (after blank line in DESCRIBE response)
    NSRange bodyRange = [response rangeOfString:@"\r\n\r\n"];
    if (bodyRange.location == NSNotFound) return nil;
    
    NSString *sdp = [response substringFromIndex:bodyRange.location + 4];
    NSLog(@"[RtspClient] SDP:\n%@", sdp);
    
    // Look for H264 video media section
    // m=video 0 RTP/AVP 96
    // a=rtpmap:96 H264/90000
    // a=fmtp:96 ...sprop-parameter-sets=...
    // a=control:trackID=0
    
    NSArray *lines = [sdp componentsSeparatedByString:@"\n"];
    
    BOOL inVideoSection = NO;
    RtspTrackInfo *track = nil;
    
    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        if ([line hasPrefix:@"m=video"]) {
            inVideoSection = YES;
            track = [RtspTrackInfo new];
            
            // Extract payload type from m=video line
            // m=video 0 RTP/AVP 96
            NSArray *parts = [line componentsSeparatedByString:@" "];
            if (parts.count >= 4) {
                track.payloadType = [parts[3] intValue];
            }
            continue;
        }
        
        if ([line hasPrefix:@"m="] && ![line hasPrefix:@"m=video"]) {
            // New media section, stop processing video
            if (inVideoSection && track) break;
            inVideoSection = NO;
            continue;
        }
        
        if (!inVideoSection || !track) continue;
        
        // a=rtpmap:96 H264/90000
        if ([line hasPrefix:@"a=rtpmap:"]) {
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"a=rtpmap:\\d+\\s+(\\w+)/(\\d+)"
                                                                                  options:0 error:nil];
            NSTextCheckingResult *match = [regex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            if (match) {
                track.codec = [line substringWithRange:[match rangeAtIndex:1]];
                track.clockRate = [[line substringWithRange:[match rangeAtIndex:2]] intValue];
            }
        }
        
        // a=fmtp:96 packetization-mode=1;profile-level-id=64001E;sprop-parameter-sets=Z2QAHqwsaoNQ9puAgICB,aM4xshs=
        if ([line hasPrefix:@"a=fmtp:"]) {
            // sprop-parameter-sets
            NSRegularExpression *spropRegex = [NSRegularExpression regularExpressionWithPattern:@"sprop-parameter-sets=([^;\\s]+)"
                                                                                       options:0 error:nil];
            NSTextCheckingResult *spropMatch = [spropRegex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            if (spropMatch) {
                track.spropParameterSets = [line substringWithRange:[spropMatch rangeAtIndex:1]];
            }
            
            // profile-level-id
            NSRegularExpression *plRegex = [NSRegularExpression regularExpressionWithPattern:@"profile-level-id=([0-9A-Fa-f]+)"
                                                                                    options:0 error:nil];
            NSTextCheckingResult *plMatch = [plRegex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            if (plMatch) {
                track.profileLevelId = [line substringWithRange:[plMatch rangeAtIndex:1]];
            }
        }
        
        // a=control:trackID=0
        if ([line hasPrefix:@"a=control:"]) {
            track.controlUrl = [line substringFromIndex:10];
        }
    }
    
    // Validate
    if (track && [track.codec.uppercaseString isEqualToString:@"H264"]) {
        if (track.clockRate == 0) track.clockRate = 90000;
        return track;
    }
    
    return nil;
}

// ─────────────────────────────────────────────────────
#pragma mark - State & error helpers
// ─────────────────────────────────────────────────────

- (void)setState:(RtspClientState)newState {
    if (_state == newState) return;
    _state = newState;
    
    NSString *stateNames[] = {@"Disconnected", @"Connecting", @"OPTIONS", @"DESCRIBE", 
                               @"SETUP", @"Playing", @"Teardown", @"Error"};
    NSLog(@"[RtspClient] State → %@", stateNames[newState]);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate rtspClient:self didChangeState:newState];
    });
}

- (void)failWithError:(NSString *)msg response:(NSString *)response {
    NSString *full = [NSString stringWithFormat:@"%@ (status=%d)", msg, [self parseStatusCode:response]];
    NSLog(@"[RtspClient] ERROR: %@", full);
    [self setState:RtspClientStateError];
    [self.delegate rtspClient:self didFailWithError:full];
}

@end
