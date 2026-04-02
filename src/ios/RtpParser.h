#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * H.264 NAL unit types we care about
 */
typedef NS_ENUM(uint8_t, NalUnitType) {
    NalUnitTypeSlice        = 1,   // non-IDR slice
    NalUnitTypeIDR          = 5,   // IDR slice (keyframe)
    NalUnitTypeSEI          = 6,   // SEI
    NalUnitTypeSPS          = 7,   // Sequence Parameter Set
    NalUnitTypePPS          = 8,   // Picture Parameter Set
    NalUnitTypeSTAP_A       = 24,  // Aggregation packet
    NalUnitTypeFU_A         = 28,  // Fragmentation unit
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
