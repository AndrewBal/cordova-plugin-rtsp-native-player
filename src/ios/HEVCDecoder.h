#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>

NS_ASSUME_NONNULL_BEGIN

@protocol HEVCDecoderDelegate <NSObject>
- (void)hevcDecoderDidDecodeFrame:(CMSampleBufferRef)sampleBuffer;
- (void)hevcDecoderDidFailWithError:(NSString *)error;
@end

/**
 * HEVCDecoder
 *
 * Hardware H.265/HEVC decoding via VideoToolbox (iOS 11+).
 * Accepts raw NAL units WITHOUT Annex B start codes, wraps them in AVCC
 * (4-byte length prefix) before feeding to VTDecompressionSession.
 *
 * Requires VPS + SPS + PPS to configure (vs. just SPS+PPS for H.264).
 *
 * Used for cameras like Hisnet 4K (HI3516CV610) that stream H.265 over RTSP.
 */
@interface HEVCDecoder : NSObject

@property (nonatomic, weak) id<HEVCDecoderDelegate> delegate;

/** Configure decoder with VPS, SPS, PPS data (in this order, RFC 7798 sprop-* fields). */
- (BOOL)configureWithVps:(NSData *)vps sps:(NSData *)sps pps:(NSData *)pps;

/** Feed a NAL unit (without start code) for decoding. */
- (void)decodeNalUnit:(NSData *)nalUnit timestamp:(uint32_t)timestamp isKeyframe:(BOOL)isKeyframe;

/** Flush and release decoder resources. */
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END