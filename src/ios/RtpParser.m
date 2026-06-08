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
    
    if (_isH265) {
        [self dispatchH265Payload:payload length:payloadLen timestamp:timestamp];
    } else {
        [self dispatchH264Payload:payload length:payloadLen timestamp:timestamp];
    }
}

- (void)dispatchH264Payload:(const uint8_t *)payload length:(NSUInteger)payloadLen timestamp:(uint32_t)timestamp {
    uint8_t nalHeader = payload[0];
    uint8_t nalType = nalHeader & 0x1F;

    if (nalType >= 1 && nalType <= 23) {
        [self emitNalUnit:[NSData dataWithBytes:payload length:payloadLen]
                     type:(NalUnitType)nalType timestamp:timestamp];
    } else if (nalType == NalUnitTypeSTAP_A) {
        [self parseStapA:payload length:payloadLen timestamp:timestamp];
    } else if (nalType == NalUnitTypeFU_A) {
        [self parseFuA:payload length:payloadLen timestamp:timestamp];
    } else {
        if (_packetsReceived % 100 == 1) {
            NSLog(@"[RtpParser] Unknown H.264 NAL type: %d", nalType);
        }
    }
}

- (void)dispatchH265Payload:(const uint8_t *)payload length:(NSUInteger)payloadLen timestamp:(uint32_t)timestamp {
    if (payloadLen < 2) return;
    // H.265 NAL header is 2 bytes: F(1)|Type(6)|LayerId(6)|TID(3)
    // Type is in upper 6 bits of byte 0 (after the forbidden bit).
    uint8_t nalType = (payload[0] >> 1) & 0x3F;

    if (nalType <= 47) {
        // Single NAL unit — emit as-is with the 2-byte header preserved
        [self emitH265NalUnit:[NSData dataWithBytes:payload length:payloadLen]
                         type:nalType timestamp:timestamp];
    } else if (nalType == H265NalUnitTypeAP) {
        [self parseH265AP:payload length:payloadLen timestamp:timestamp];
    } else if (nalType == H265NalUnitTypeFU) {
        [self parseH265FU:payload length:payloadLen timestamp:timestamp];
    } else {
        if (_packetsReceived % 100 == 1) {
            NSLog(@"[RtpParser] Unknown H.265 NAL type: %d", nalType);
        }
    }
}

// H.265 Aggregation Packet (RFC 7798 §4.4.2)
// Layout: PayloadHdr(2 bytes, type=48) + [NALU size(2 BE) + NAL data]+
// (DONL not supported — Hisnet doesn't use it; sprop-max-don-diff absent)
- (void)parseH265AP:(const uint8_t *)payload length:(NSUInteger)length timestamp:(uint32_t)timestamp {
    NSUInteger offset = 2;  // skip 2-byte AP payload header
    while (offset + 2 < length) {
        uint16_t nalSize = ((uint16_t)payload[offset] << 8) | payload[offset + 1];
        offset += 2;
        if (offset + nalSize > length) {
            NSLog(@"[RtpParser] H.265 AP NAL size overflows packet");
            break;
        }
        uint8_t type = (payload[offset] >> 1) & 0x3F;
        NSData *nalData = [NSData dataWithBytes:payload + offset length:nalSize];
        [self emitH265NalUnit:nalData type:type timestamp:timestamp];
        offset += nalSize;
    }
}

// H.265 Fragmentation Unit (RFC 7798 §4.4.3)
// Layout: PayloadHdr(2 bytes, type=49) + FU header(1 byte: S|E|FuType(6)) + data
- (void)parseH265FU:(const uint8_t *)payload length:(NSUInteger)length timestamp:(uint32_t)timestamp {
    if (length < 3) return;

    uint8_t payloadHdr0 = payload[0];   // F + Type(49) + LayerId_high
    uint8_t payloadHdr1 = payload[1];   // LayerId_low + TID
    uint8_t fuHeader    = payload[2];

    BOOL startBit = (fuHeader >> 7) & 0x01;
    BOOL endBit   = (fuHeader >> 6) & 0x01;
    uint8_t nalType = fuHeader & 0x3F;

    if (startBit) {
        [_fuaBuffer setLength:0];
        // Reconstruct the original 2-byte NAL header for the inner NAL.
        // Take F + LayerId_high from payloadHdr0, replace type bits with FU's nalType.
        // payloadHdr0 layout: F(1) | Type(6) | LayerId_high(1)
        uint8_t reconHdr0 = (payloadHdr0 & 0x81) | (nalType << 1);
        uint8_t hdr[2] = { reconHdr0, payloadHdr1 };
        [_fuaBuffer appendBytes:hdr length:2];
        _fuaTimestamp = timestamp;
        _fuaInProgress = YES;
    }

    if (!_fuaInProgress) return;

    if (length > 3) {
        [_fuaBuffer appendBytes:payload + 3 length:length - 3];
    }

    if (endBit) {
        uint8_t finalType = (((const uint8_t *)_fuaBuffer.bytes)[0] >> 1) & 0x3F;
        [self emitH265NalUnit:[NSData dataWithData:_fuaBuffer]
                         type:finalType timestamp:_fuaTimestamp];
        [_fuaBuffer setLength:0];
        _fuaInProgress = NO;
    }
}

- (void)emitH265NalUnit:(NSData *)nalData type:(uint8_t)type timestamp:(uint32_t)timestamp {
    _nalUnitsEmitted++;
    if (_nalUnitsEmitted <= 5 || _nalUnitsEmitted % 100 == 0) {
        NSString *typeStr;
        switch (type) {
            case H265NalUnitTypeVPS_NUT: typeStr = @"VPS"; break;
            case H265NalUnitTypeSPS_NUT: typeStr = @"SPS"; break;
            case H265NalUnitTypePPS_NUT: typeStr = @"PPS"; break;
            case H265NalUnitTypeIDR_W_RADL:
            case H265NalUnitTypeIDR_N_LP: typeStr = @"IDR"; break;
            case H265NalUnitTypeCRA_NUT: typeStr = @"CRA"; break;
            case H265NalUnitTypeTRAIL_N:
            case H265NalUnitTypeTRAIL_R: typeStr = @"Trail"; break;
            case H265NalUnitTypePREFIX_SEI:
            case H265NalUnitTypeSUFFIX_SEI: typeStr = @"SEI"; break;
            default: typeStr = [NSString stringWithFormat:@"H265Type%d", type]; break;
        }
        NSLog(@"[RtpParser] H.265 NAL #%lu: %@ (%lu bytes) ts=%u",
              (unsigned long)_nalUnitsEmitted, typeStr, (unsigned long)nalData.length, timestamp);
    }
    // Reuse the same delegate method — type values won't collide with H.264 values
    // because PlayerManager dispatches by codec mode.
    [_delegate rtpParserDidReceiveNalUnit:nalData type:(NalUnitType)type timestamp:timestamp];
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
