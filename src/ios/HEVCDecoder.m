#import "HEVCDecoder.h"

static void hevcDecompressionOutputCallback(void *decompressionOutputRefCon,
                                             void *sourceFrameRefCon,
                                             OSStatus status,
                                             VTDecodeInfoFlags infoFlags,
                                             CVImageBufferRef imageBuffer,
                                             CMTime presentationTimeStamp,
                                             CMTime presentationDuration);

@interface HEVCDecoder ()
@property (nonatomic, assign) CMVideoFormatDescriptionRef formatDescription;
@property (nonatomic, assign) VTDecompressionSessionRef session;
@property (nonatomic, assign) BOOL configured;
@property (nonatomic, assign) NSUInteger framesReceived;
@property (nonatomic, assign) NSUInteger framesDecoded;
@property (nonatomic, strong) NSData *currentVps;
@property (nonatomic, strong) NSData *currentSps;
@property (nonatomic, strong) NSData *currentPps;
@end

@implementation HEVCDecoder

- (void)dealloc {
    [self teardownSession];
}

- (BOOL)configureWithVps:(NSData *)vps sps:(NSData *)sps pps:(NSData *)pps {
    if (!vps || !sps || !pps || vps.length == 0 || sps.length == 0 || pps.length == 0) {
        NSLog(@"[HEVCDecoder] Invalid VPS/SPS/PPS data");
        return NO;
    }

    if (_configured &&
        [_currentVps isEqualToData:vps] &&
        [_currentSps isEqualToData:sps] &&
        [_currentPps isEqualToData:pps]) {
        return YES;
    }

    [self teardownSession];

    _currentVps = [vps copy];
    _currentSps = [sps copy];
    _currentPps = [pps copy];

    NSLog(@"[HEVCDecoder] Configuring with VPS(%lu) SPS(%lu) PPS(%lu)",
          (unsigned long)vps.length, (unsigned long)sps.length, (unsigned long)pps.length);

    // CMVideoFormatDescriptionCreateFromHEVCParameterSets is iOS 11+.
    // Build the param set arrays — order matters: VPS, SPS, PPS.
    const uint8_t *paramSetPtrs[3] = {
        (const uint8_t *)vps.bytes,
        (const uint8_t *)sps.bytes,
        (const uint8_t *)pps.bytes
    };
    const size_t paramSetSizes[3] = { vps.length, sps.length, pps.length };

    OSStatus status = noErr;
    if (@available(iOS 11.0, *)) {
        status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            kCFAllocatorDefault,
            3,                  // parameterSetCount
            paramSetPtrs,
            paramSetSizes,
            4,                  // NAL unit header length (AVCC = 4)
            NULL,               // extensions
            &_formatDescription
        );
    } else {
        NSLog(@"[HEVCDecoder] iOS < 11, HEVC not supported");
        return NO;
    }

    if (status != noErr) {
        NSLog(@"[HEVCDecoder] Failed to create format description: %d", (int)status);
        return NO;
    }

    CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(_formatDescription);
    NSLog(@"[HEVCDecoder] Video dimensions: %dx%d", dim.width, dim.height);

    NSDictionary *destAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    VTDecompressionOutputCallbackRecord cbRecord;
    cbRecord.decompressionOutputCallback = hevcDecompressionOutputCallback;
    cbRecord.decompressionOutputRefCon = (__bridge void *)self;

    status = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        _formatDescription,
        NULL,
        (__bridge CFDictionaryRef)destAttrs,
        &cbRecord,
        &_session
    );

    if (status != noErr) {
        NSLog(@"[HEVCDecoder] Failed to create decompression session: %d", (int)status);
        if (_formatDescription) {
            CFRelease(_formatDescription);
            _formatDescription = NULL;
        }
        return NO;
    }

    VTSessionSetProperty(_session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);

    _configured = YES;
    NSLog(@"[HEVCDecoder] Decoder configured ✓ (%dx%d)", dim.width, dim.height);
    return YES;
}

- (void)decodeNalUnit:(NSData *)nalUnit timestamp:(uint32_t)timestamp isKeyframe:(BOOL)isKeyframe {
    _framesReceived++;
    if (!_configured || !_session) return;

    uint32_t nalLen = (uint32_t)nalUnit.length;
    uint32_t lenBE = CFSwapInt32HostToBig(nalLen);

    size_t totalLen = 4 + nalUnit.length;
    uint8_t *buf = malloc(totalLen);
    if (!buf) return;

    memcpy(buf, &lenBE, 4);
    memcpy(buf + 4, nalUnit.bytes, nalUnit.length);

    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, buf, totalLen,
        kCFAllocatorMalloc, NULL, 0, totalLen, 0, &blockBuffer);

    if (status != noErr || !blockBuffer) {
        free(buf);
        return;
    }

    CMSampleBufferRef sampleBuffer = NULL;
    const size_t sampleSizes[] = { totalLen };

    CMTime pts = CMTimeMake(timestamp, 90000);
    CMSampleTimingInfo timing = {
        .presentationTimeStamp = pts,
        .duration = CMTimeMake(1, 25),
        .decodeTimeStamp = kCMTimeInvalid
    };

    status = CMSampleBufferCreateReady(
        kCFAllocatorDefault, blockBuffer, _formatDescription,
        1, 1, &timing, 1, sampleSizes, &sampleBuffer);

    CFRelease(blockBuffer);
    if (status != noErr || !sampleBuffer) return;

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

    VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression
                             | kVTDecodeFrame_1xRealTimePlayback;
    VTDecodeInfoFlags infoFlags = 0;
    status = VTDecompressionSessionDecodeFrame(_session, sampleBuffer, flags, NULL, &infoFlags);

    CFRelease(sampleBuffer);

    if (status != noErr) {
        if (_framesReceived <= 5 || _framesReceived % 500 == 0) {
            NSLog(@"[HEVCDecoder] Decode error: %d (frame #%lu, key=%d)",
                  (int)status, (unsigned long)_framesReceived, isKeyframe);
        }
        if (status == kVTInvalidSessionErr && _currentVps && _currentSps && _currentPps) {
            NSLog(@"[HEVCDecoder] Session invalid, recreating...");
            _configured = NO;
            [self configureWithVps:_currentVps sps:_currentSps pps:_currentPps];
        }
    }
}

- (void)didDecodeImageBuffer:(CVImageBufferRef)imageBuffer
                         pts:(CMTime)pts
                    duration:(CMTime)duration
                      status:(OSStatus)status {
    if (status != noErr || !imageBuffer) return;

    _framesDecoded++;
    if (_framesDecoded <= 3 || _framesDecoded % 500 == 0) {
        NSLog(@"[HEVCDecoder] Decoded frame #%lu (%.3fs)",
              (unsigned long)_framesDecoded, CMTimeGetSeconds(pts));
    }

    CMVideoFormatDescriptionRef videoFmt = NULL;
    OSStatus fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault, imageBuffer, &videoFmt);
    if (fmtStatus != noErr || !videoFmt) return;

    CMSampleTimingInfo timing = {
        .presentationTimeStamp = pts,
        .duration = duration,
        .decodeTimeStamp = kCMTimeInvalid
    };

    CMSampleBufferRef outBuffer = NULL;
    OSStatus bufStatus = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault, imageBuffer, true,
        NULL, NULL, videoFmt, &timing, &outBuffer);

    CFRelease(videoFmt);
    if (bufStatus != noErr || !outBuffer) return;

    [_delegate hevcDecoderDidDecodeFrame:outBuffer];
    CFRelease(outBuffer);
}

- (void)invalidate {
    NSLog(@"[HEVCDecoder] Invalidated (received: %lu, decoded: %lu)",
          (unsigned long)_framesReceived, (unsigned long)_framesDecoded);
    [self teardownSession];
    _framesReceived = 0;
    _framesDecoded = 0;
    _currentVps = nil;
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

static void hevcDecompressionOutputCallback(void *decompressionOutputRefCon,
                                             void *sourceFrameRefCon,
                                             OSStatus status,
                                             VTDecodeInfoFlags infoFlags,
                                             CVImageBufferRef imageBuffer,
                                             CMTime presentationTimeStamp,
                                             CMTime presentationDuration) {
    HEVCDecoder *decoder = (__bridge HEVCDecoder *)decompressionOutputRefCon;
    [decoder didDecodeImageBuffer:imageBuffer
                              pts:presentationTimeStamp
                         duration:presentationDuration
                           status:status];
}