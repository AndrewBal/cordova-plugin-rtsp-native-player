#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>

NS_ASSUME_NONNULL_BEGIN

@protocol H264DecoderDelegate <NSObject>

/**
 * Called on the decode queue when a frame has been decoded.
 * sampleBuffer is ready for AVSampleBufferDisplayLayer.
 */
- (void)h264DecoderDidDecodeFrame:(CMSampleBufferRef)sampleBuffer;

/** Decoder encountered an error */
- (void)h264DecoderDidFailWithError:(NSString *)error;

@end

/**
 * H264Decoder
 *
 * Hardware H.264 decoding via VideoToolbox.
 * Accepts raw NAL units (without Annex B start codes).
 * Outputs CMSampleBuffers suitable for AVSampleBufferDisplayLayer.
 *
 * Phase 1: stub — logs NAL units received.
 * Phase 3: full VideoToolbox implementation.
 */
@interface H264Decoder : NSObject

@property (nonatomic, weak) id<H264DecoderDelegate> delegate;

/** Configure decoder with SPS and PPS data */
- (BOOL)configureWithSps:(NSData *)sps pps:(NSData *)pps;

/** Feed a NAL unit for decoding */
- (void)decodeNalUnit:(NSData *)nalUnit timestamp:(uint32_t)timestamp isKeyframe:(BOOL)isKeyframe;

/** Flush and release decoder resources */
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
