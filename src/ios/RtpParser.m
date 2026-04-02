#import "RtpParser.h"

@interface RtpParser ()

@property (nonatomic, readwrite) NSUInteger packetsReceived;
@property (nonatomic, readwrite) NSUInteger nalUnitsEmitted;

// FU-A reassembly buffer
@property (nonatomic, strong) NSMutableData *fuaBuffer;
@property (nonatomic, assign) uint32_t fuaTimestamp;
@property (nonatomic, assign) BOOL fuaInProgress;

@end

@implementation RtpParser

- (instancetype)init {
    self = [super init];
    if (self) {
        _fuaBuffer = [NSMutableData new];
        _fuaInProgress = NO;
    }
    return self;
}

- (void)reset {
    _packetsReceived = 0;
    _nalUnitsEmitted = 0;
    [_fuaBuffer setLength:0];
    _fuaInProgress = NO;
}

// ─────────────────────────────────────────────
#pragma mark - RTP Packet Parsing
// ─────────────────────────────────────────────

- (void)feedRtpPacket:(NSData *)rtpData {
    _packetsReceived++;
    
    // RTP header is at least 12 bytes
    if (rtpData.length < 12) {
        NSLog(@"[RtpParser] Packet too short: %lu bytes", (unsigned long)rtpData.length);
        return;
    }
    
    const uint8_t *bytes = (const uint8_t *)rtpData.bytes;
    
    // RTP header fields
    // uint8_t version = (bytes[0] >> 6) & 0x03;
    // BOOL padding = (bytes[0] >> 5) & 0x01;
    // BOOL extension = (bytes[0] >> 4) & 0x01;
    uint8_t csrcCount = bytes[0] & 0x0F;
    // BOOL marker = (bytes[1] >> 7) & 0x01;
    // uint8_t payloadType = bytes[1] & 0x7F;
    // uint16_t seqNum = ((uint16_t)bytes[2] << 8) | bytes[3];
    uint32_t timestamp = ((uint32_t)bytes[4] << 24) | ((uint32_t)bytes[5] << 16) |
                         ((uint32_t)bytes[6] << 8)  | bytes[7];
    // uint32_t ssrc = ... bytes[8..11]
    
    // Calculate payload offset (skip RTP header + CSRC entries)
    NSUInteger headerLen = 12 + csrcCount * 4;
    
    // Check for header extension
    BOOL extension = (bytes[0] >> 4) & 0x01;
    if (extension) {
        if (rtpData.length < headerLen + 4) return;
        // Extension header: 2 bytes profile + 2 bytes length (in 32-bit words)
        uint16_t extLen = ((uint16_t)bytes[headerLen + 2] << 8) | bytes[headerLen + 3];
        headerLen += 4 + extLen * 4;
    }
    
    if (rtpData.length <= headerLen) {
        return;  // No payload
    }
    
    const uint8_t *payload = bytes + headerLen;
    NSUInteger payloadLen = rtpData.length - headerLen;
    
    // First byte of payload is the NAL unit header (or FU indicator)
    uint8_t nalHeader = payload[0];
    uint8_t nalType = nalHeader & 0x1F;
    
    if (nalType >= 1 && nalType <= 23) {
        // Single NAL unit packet
        [self emitNalUnit:[NSData dataWithBytes:payload length:payloadLen]
                     type:(NalUnitType)nalType
                timestamp:timestamp];
        
    } else if (nalType == NalUnitTypeSTAP_A) {
        // STAP-A: aggregation packet — multiple NALs in one RTP
        [self parseStapA:payload length:payloadLen timestamp:timestamp];
        
    } else if (nalType == NalUnitTypeFU_A) {
        // FU-A: fragmented NAL — reassemble from multiple RTP packets
        [self parseFuA:payload length:payloadLen timestamp:timestamp];
        
    } else {
        // Log once per 100 unknown types to avoid spam
        if (_packetsReceived % 100 == 1) {
            NSLog(@"[RtpParser] Unknown NAL type: %d", nalType);
        }
    }
}

// ─────────────────────────────────────────────
#pragma mark - STAP-A (type 24)
// ─────────────────────────────────────────────

- (void)parseStapA:(const uint8_t *)payload length:(NSUInteger)length timestamp:(uint32_t)timestamp {
    // Skip the STAP-A header byte
    NSUInteger offset = 1;
    
    while (offset + 2 < length) {
        // 2-byte NAL size (big-endian)
        uint16_t nalSize = ((uint16_t)payload[offset] << 8) | payload[offset + 1];
        offset += 2;
        
        if (offset + nalSize > length) {
            NSLog(@"[RtpParser] STAP-A NAL size overflows packet");
            break;
        }
        
        uint8_t type = payload[offset] & 0x1F;
        NSData *nalData = [NSData dataWithBytes:payload + offset length:nalSize];
        [self emitNalUnit:nalData type:(NalUnitType)type timestamp:timestamp];
        
        offset += nalSize;
    }
}

// ─────────────────────────────────────────────
#pragma mark - FU-A (type 28)
// ─────────────────────────────────────────────

- (void)parseFuA:(const uint8_t *)payload length:(NSUInteger)length timestamp:(uint32_t)timestamp {
    if (length < 2) return;
    
    // FU indicator (byte 0): F|NRI|Type(28)
    uint8_t fuIndicator = payload[0];
    uint8_t nri = fuIndicator & 0x60;  // NRI bits
    
    // FU header (byte 1): S|E|R|Type
    uint8_t fuHeader = payload[1];
    BOOL startBit = (fuHeader >> 7) & 0x01;
    BOOL endBit   = (fuHeader >> 6) & 0x01;
    uint8_t nalType = fuHeader & 0x1F;
    
    if (startBit) {
        // Start of fragmented NAL — reconstruct the NAL header byte
        [_fuaBuffer setLength:0];
        uint8_t reconstructedHeader = nri | nalType;
        [_fuaBuffer appendBytes:&reconstructedHeader length:1];
        _fuaTimestamp = timestamp;
        _fuaInProgress = YES;
    }
    
    if (!_fuaInProgress) {
        // Got middle/end fragment without start — discard
        return;
    }
    
    // Append fragment payload (skip FU indicator + FU header = 2 bytes)
    if (length > 2) {
        [_fuaBuffer appendBytes:payload + 2 length:length - 2];
    }
    
    if (endBit) {
        // Complete NAL assembled
        uint8_t finalType = ((const uint8_t *)_fuaBuffer.bytes)[0] & 0x1F;
        [self emitNalUnit:[NSData dataWithData:_fuaBuffer]
                     type:(NalUnitType)finalType
                timestamp:_fuaTimestamp];
        [_fuaBuffer setLength:0];
        _fuaInProgress = NO;
    }
}

// ─────────────────────────────────────────────
#pragma mark - NAL emission
// ─────────────────────────────────────────────

- (void)emitNalUnit:(NSData *)nalData type:(NalUnitType)type timestamp:(uint32_t)timestamp {
    _nalUnitsEmitted++;
    
    // Periodic logging to verify data flow
    if (_nalUnitsEmitted <= 5 || _nalUnitsEmitted % 100 == 0) {
        NSString *typeStr;
        switch (type) {
            case NalUnitTypeSPS:   typeStr = @"SPS"; break;
            case NalUnitTypePPS:   typeStr = @"PPS"; break;
            case NalUnitTypeIDR:   typeStr = @"IDR"; break;
            case NalUnitTypeSlice: typeStr = @"Slice"; break;
            case NalUnitTypeSEI:   typeStr = @"SEI"; break;
            default: typeStr = [NSString stringWithFormat:@"Type%d", type]; break;
        }
        NSLog(@"[RtpParser] NAL #%lu: %@ (%lu bytes) ts=%u",
              (unsigned long)_nalUnitsEmitted, typeStr, (unsigned long)nalData.length, timestamp);
    }
    
    [_delegate rtpParserDidReceiveNalUnit:nalData type:type timestamp:timestamp];
}

@end
