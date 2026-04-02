#import "H264Decoder.h"

// Forward declaration of C callback
static void decompressionOutputCallback(void *decompressionOutputRefCon,
                                         void *sourceFrameRefCon,
                                         OSStatus status,
                                         VTDecodeInfoFlags infoFlags,
                                         CVImageBufferRef imageBuffer,
                                         CMTime presentationTimeStamp,
                                         CMTime presentationDuration);

@interface H264Decoder ()

@property (nonatomic, assign) CMVideoFormatDescriptionRef formatDescription;
@property (nonatomic, assign) VTDecompressionSessionRef session;
@property (nonatomic, assign) BOOL configured;
@property (nonatomic, assign) NSUInteger framesReceived;
@property (nonatomic, assign) NSUInteger framesDecoded;

// Keep SPS/PPS for session recreation
@property (nonatomic, strong) NSData *currentSps;
@property (nonatomic, strong) NSData *currentPps;

@end

@implementation H264Decoder

- (void)dealloc {
    [self teardownSession];
}

// ─────────────────────────────────────────────
#pragma mark - Configuration
// ─────────────────────────────────────────────

- (BOOL)configureWithSps:(NSData *)sps pps:(NSData *)pps {
    if (!sps || !pps || sps.length == 0 || pps.length == 0) {
        NSLog(@"[H264Decoder] Invalid SPS/PPS data");
        return NO;
    }
    
    // If already configured with same SPS/PPS, skip
    if (_configured && [_currentSps isEqualToData:sps] && [_currentPps isEqualToData:pps]) {
        return YES;
    }
    
    // Tear down existing session
    [self teardownSession];
    
    _currentSps = [sps copy];
    _currentPps = [pps copy];
    
    NSLog(@"[H264Decoder] Configuring with SPS (%lu bytes) PPS (%lu bytes)",
          (unsigned long)sps.length, (unsigned long)pps.length);
    
    // Create format description from SPS + PPS
    const uint8_t *paramSetPtrs[2] = {
        (const uint8_t *)sps.bytes,
        (const uint8_t *)pps.bytes
    };
    const size_t paramSetSizes[2] = {
        sps.length,
        pps.length
    };
    
    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault,
        2,                  // parameterSetCount
        paramSetPtrs,
        paramSetSizes,
        4,                  // NAL unit header length (AVCC uses 4)
        &_formatDescription
    );
    
    if (status != noErr) {
        NSLog(@"[H264Decoder] Failed to create format description: %d", (int)status);
        return NO;
    }
    
    CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(_formatDescription);
    NSLog(@"[H264Decoder] Video dimensions: %dx%d", dim.width, dim.height);
    
    // Create decompression session
    NSDictionary *destAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    
    VTDecompressionOutputCallbackRecord cbRecord;
    cbRecord.decompressionOutputCallback = decompressionOutputCallback;
    cbRecord.decompressionOutputRefCon = (__bridge void *)self;
    
    status = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        _formatDescription,
        NULL,                                        // decoderSpecification
        (__bridge CFDictionaryRef)destAttrs,
        &cbRecord,
        &_session
    );
    
    if (status != noErr) {
        NSLog(@"[H264Decoder] Failed to create decompression session: %d", (int)status);
        if (_formatDescription) {
            CFRelease(_formatDescription);
            _formatDescription = NULL;
        }
        return NO;
    }
    
    // Low-latency real-time mode
    VTSessionSetProperty(_session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    
    _configured = YES;
    NSLog(@"[H264Decoder] Decoder configured ✓ (%dx%d)", dim.width, dim.height);
    return YES;
}

// ─────────────────────────────────────────────
#pragma mark - Decode
// ─────────────────────────────────────────────

- (void)decodeNalUnit:(NSData *)nalUnit timestamp:(uint32_t)timestamp isKeyframe:(BOOL)isKeyframe {
    _framesReceived++;
    
    if (!_configured || !_session) {
        return;
    }
    
    // AVCC format: 4-byte big-endian length prefix + NAL data
    uint32_t nalLen = (uint32_t)nalUnit.length;
    uint32_t lenBE = CFSwapInt32HostToBig(nalLen);
    
    size_t totalLen = 4 + nalUnit.length;
    uint8_t *buf = malloc(totalLen);
    if (!buf) return;
    
    memcpy(buf, &lenBE, 4);
    memcpy(buf + 4, nalUnit.bytes, nalUnit.length);
    
    // Create CMBlockBuffer (takes ownership of buf via deallocator)
    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        buf,
        totalLen,
        kCFAllocatorMalloc,     // frees buf when done
        NULL,
        0,
        totalLen,
        0,
        &blockBuffer
    );
    
    if (status != noErr || !blockBuffer) {
        free(buf);
        return;
    }
    
    // Create CMSampleBuffer
    CMSampleBufferRef sampleBuffer = NULL;
    const size_t sampleSizes[] = { totalLen };
    
    CMTime pts = CMTimeMake(timestamp, 90000);
    CMSampleTimingInfo timing;
    timing.presentationTimeStamp = pts;
    timing.duration = CMTimeMake(1, 22);
    timing.decodeTimeStamp = kCMTimeInvalid;
    
    status = CMSampleBufferCreateReady(
        kCFAllocatorDefault,
        blockBuffer,
        _formatDescription,
        1,              // numSamples
        1,              // numSampleTimingEntries
        &timing,
        1,              // numSampleSizeEntries
        sampleSizes,
        &sampleBuffer
    );
    
    CFRelease(blockBuffer);
    
    if (status != noErr || !sampleBuffer) {
        return;
    }
    
    // Set sync/dependency attachments
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        if (isKeyframe) {
            CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync, kCFBooleanFalse);
        } else {
            CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
            CFDictionarySetValue(dict, kCMSampleAttachmentKey_DependsOnOthers, kCFBooleanTrue);
        }
    }
    
    // Submit for decoding
    VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression
                             | kVTDecodeFrame_1xRealTimePlayback;
    VTDecodeInfoFlags infoFlags = 0;
    
    status = VTDecompressionSessionDecodeFrame(_session, sampleBuffer, flags, NULL, &infoFlags);
    
    CFRelease(sampleBuffer);
    
    if (status != noErr) {
        if (_framesReceived <= 5 || _framesReceived % 500 == 0) {
            NSLog(@"[H264Decoder] Decode error: %d (frame #%lu, key=%d)",
                  (int)status, (unsigned long)_framesReceived, isKeyframe);
        }
        // Recreate session if invalid
        if (status == kVTInvalidSessionErr && _currentSps && _currentPps) {
            NSLog(@"[H264Decoder] Session invalid, recreating...");
            _configured = NO;
            [self configureWithSps:_currentSps pps:_currentPps];
        }
    }
}

// ─────────────────────────────────────────────
#pragma mark - Decode callback (called by VT)
// ─────────────────────────────────────────────

- (void)didDecodeImageBuffer:(CVImageBufferRef)imageBuffer
                         pts:(CMTime)pts
                    duration:(CMTime)duration
                      status:(OSStatus)status {
    
    if (status != noErr || !imageBuffer) {
        return;
    }
    
    _framesDecoded++;
    
    if (_framesDecoded <= 3 || _framesDecoded % 500 == 0) {
        NSLog(@"[H264Decoder] Decoded frame #%lu (%.3fs)",
              (unsigned long)_framesDecoded, CMTimeGetSeconds(pts));
    }
    
    // Wrap decoded CVPixelBuffer into CMSampleBuffer for AVSampleBufferDisplayLayer
    CMVideoFormatDescriptionRef videoFmt = NULL;
    OSStatus fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault, imageBuffer, &videoFmt);
    
    if (fmtStatus != noErr || !videoFmt) return;
    
    CMSampleTimingInfo timing;
    timing.presentationTimeStamp = pts;
    timing.duration = duration;
    timing.decodeTimeStamp = kCMTimeInvalid;
    
    CMSampleBufferRef outBuffer = NULL;
    OSStatus bufStatus = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault, imageBuffer, true,
        NULL, NULL, videoFmt, &timing, &outBuffer);
    
    CFRelease(videoFmt);
    
    if (bufStatus != noErr || !outBuffer) return;
    
    [_delegate h264DecoderDidDecodeFrame:outBuffer];
    
    CFRelease(outBuffer);
}

// ─────────────────────────────────────────────
#pragma mark - Teardown
// ─────────────────────────────────────────────

- (void)invalidate {
    NSLog(@"[H264Decoder] Invalidated (received: %lu, decoded: %lu)",
          (unsigned long)_framesReceived, (unsigned long)_framesDecoded);
    [self teardownSession];
    _framesReceived = 0;
    _framesDecoded = 0;
    _currentSps = nil;
    _currentPps = nil;
}

- (void)teardownSession {
    if (_session) {
        VTDecompressionSessionWaitForAsynchronousFrames(_session);
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    if (_formatDescription) {
        CFRelease(_formatDescription);
        _formatDescription = NULL;
    }
    _configured = NO;
}

@end

// ─────────────────────────────────────────────
// C callback → ObjC bridge
// ─────────────────────────────────────────────

static void decompressionOutputCallback(void *decompressionOutputRefCon,
                                         void *sourceFrameRefCon,
                                         OSStatus status,
                                         VTDecodeInfoFlags infoFlags,
                                         CVImageBufferRef imageBuffer,
                                         CMTime presentationTimeStamp,
                                         CMTime presentationDuration) {
    H264Decoder *decoder = (__bridge H264Decoder *)decompressionOutputRefCon;
    [decoder didDecodeImageBuffer:imageBuffer
                             pts:presentationTimeStamp
                        duration:presentationDuration
                          status:status];
}
