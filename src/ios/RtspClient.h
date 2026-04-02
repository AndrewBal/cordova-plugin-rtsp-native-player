#import <Foundation/Foundation.h>
#import <Network/Network.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Parsed SDP track info extracted from DESCRIBE response
 */
@interface RtspTrackInfo : NSObject
@property (nonatomic, copy) NSString *controlUrl;    // e.g. "trackID=0"
@property (nonatomic, copy) NSString *codec;         // e.g. "H264"
@property (nonatomic, assign) int payloadType;       // e.g. 96
@property (nonatomic, assign) int clockRate;         // e.g. 90000
@property (nonatomic, copy, nullable) NSString *spropParameterSets;  // base64 SPS,PPS
@property (nonatomic, copy, nullable) NSString *profileLevelId;
@end

/**
 * RTSP session state
 */
typedef NS_ENUM(NSInteger, RtspClientState) {
    RtspClientStateDisconnected = 0,
    RtspClientStateConnecting,
    RtspClientStateOptions,
    RtspClientStateDescribe,
    RtspClientStateSetup,
    RtspClientStatePlaying,
    RtspClientStateTeardown,
    RtspClientStateError
};

@protocol RtspClientDelegate <NSObject>

/** RTSP session state changed */
- (void)rtspClient:(id)client didChangeState:(RtspClientState)state;

/** Received interleaved RTP data on a channel */
- (void)rtspClient:(id)client didReceiveRtpData:(NSData *)data channel:(uint8_t)channel;

/** Parsed SDP track info available (after DESCRIBE) */
- (void)rtspClient:(id)client didReceiveTrackInfo:(RtspTrackInfo *)trackInfo;

/** Fatal error */
- (void)rtspClient:(id)client didFailWithError:(NSString *)error;

@end

/**
 * RtspClient
 *
 * Uses NWConnection (Network.framework) with requiredInterfaceType = .wifi
 * to guarantee traffic goes over the dashcam's WiFi hotspot, not cellular.
 *
 * Implements RTSP handshake: OPTIONS → DESCRIBE → SETUP (TCP interleaved) → PLAY
 * Then continuously reads TCP interleaved RTP frames and delivers them to delegate.
 */
@interface RtspClient : NSObject

@property (nonatomic, weak) id<RtspClientDelegate> delegate;
@property (nonatomic, readonly) RtspClientState state;
@property (nonatomic, readonly, copy) NSString *rtspUrl;

/** Keepalive interval in seconds (default 3.0, matching camera expectation) */
@property (nonatomic, assign) NSTimeInterval keepaliveInterval;

- (instancetype)initWithUrl:(NSString *)rtspUrl;

/** Connect and start RTSP handshake */
- (void)start;

/** Send TEARDOWN and close connection */
- (void)stop;

@end

NS_ASSUME_NONNULL_END
