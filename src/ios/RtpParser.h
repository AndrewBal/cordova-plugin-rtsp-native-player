#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * H.264 NAL unit types we care about
 */
// H.264 NAL types (RFC 6184) — 5-bit type, single-byte header
typedef NS_ENUM(uint8_t, NalUnitType) {
    NalUnitTypeSlice        = 1,
    NalUnitTypeIDR          = 5,
    NalUnitTypeSEI          = 6,
    NalUnitTypeSPS          = 7,
    NalUnitTypePPS          = 8,
    NalUnitTypeSTAP_A       = 24,
    NalUnitTypeFU_A         = 28,
};

// H.265 NAL types (RFC 7798) — 6-bit type, two-byte header
typedef NS_ENUM(uint8_t, H265NalUnitType) {
    H265NalUnitTypeTRAIL_N   = 0,
    H265NalUnitTypeTRAIL_R   = 1,
    H265NalUnitTypeIDR_W_RADL = 19,
    H265NalUnitTypeIDR_N_LP  = 20,
    H265NalUnitTypeCRA_NUT   = 21,
    H265NalUnitTypeVPS_NUT   = 32,
    H265NalUnitTypeSPS_NUT   = 33,
    H265NalUnitTypePPS_NUT   = 34,
    H265NalUnitTypePREFIX_SEI = 39,
    H265NalUnitTypeSUFFIX_SEI = 40,
    H265NalUnitTypeAP        = 48,  // Aggregation Packet
    H265NalUnitTypeFU        = 49,  // Fragmentation Unit
};

@protocol RtpParserDelegate <NSObject>

/**
 * Called when a complete H.264 NAL unit has been assembled from RTP packets.
 * The data does NOT include the 4-byte Annex B start code (0x00000001).
 */
- (void)rtpParserDidReceiveNalUnit:(NSData *)nalUnit type:(NalUnitType)type timestamp:(uint32_t)timestamp;

@end

/**
 * RtpParser
 *
 * Parses RTP packets (RFC 3550) containing H.264 NAL units (RFC 6184).
 * Handles:
 *  - Single NAL unit packets (types 1-23)
 *  - STAP-A aggregation packets (type 24)
 *  - FU-A fragmentation packets (type 28)
 */
@interface RtpParser : NSObject

@property (nonatomic, weak) id<RtpParserDelegate> delegate;

/** Set codec mode. NO (default) = H.264. YES = H.265. Must be set before feeding packets. */
@property (nonatomic, assign) BOOL isH265;

/** Number of RTP packets processed */
@property (nonatomic, readonly) NSUInteger packetsReceived;

/** Number of complete NAL units emitted */
@property (nonatomic, readonly) NSUInteger nalUnitsEmitted;

/**
 * Feed an RTP packet payload (without the TCP interleaved header).
 * The parser extracts H.264 NAL units and delivers them to delegate.
 */
- (void)feedRtpPacket:(NSData *)rtpData;

/** Reset parser state (e.g. on stream restart) */
- (void)reset;

@end

NS_ASSUME_NONNULL_END
