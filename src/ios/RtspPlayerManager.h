#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "RtspClient.h"
#import "RtpParser.h"
#import "H264Decoder.h"
#import "PlayerViewController.h"

NS_ASSUME_NONNULL_BEGIN

@protocol RtspPlayerManagerDelegate <NSObject>

/** Status updates: STARTING, CONNECTING, PLAYING, BUFFERING, SWITCHING_CAMERA, CLOSED */
- (void)playerManager:(id)manager didChangeStatus:(NSString *)status message:(nullable NSString *)message;

/** Error occurred */
- (void)playerManager:(id)manager didFailWithError:(NSString *)error;

/** User action from player UI */
- (void)playerManager:(id)manager didReceiveAction:(NSString *)action camera:(nullable NSString *)camera data:(nullable NSDictionary *)data;

@end

/**
 * RtspPlayerManager
 *
 * High-level coordinator:
 * - Creates RtspClient for RTSP/NWConnection
 * - Feeds RTP data through RtpParser → H264Decoder → PlayerViewController
 * - Manages player UI lifecycle (present/dismiss)
 * - Handles camera switching (stop RTSP → getcamchnl.cgi → restart RTSP)
 * - Handles photo/record commands via HTTP API
 */
@interface RtspPlayerManager : NSObject

@property (nonatomic, weak) id<RtspPlayerManagerDelegate> delegate;

/**
 * Start playback
 * @param frontUrl    RTSP URL for front camera
 * @param rearUrl     RTSP URL for rear camera (may be nil)
 * @param title       Player title
 * @param apiBaseUrl  Camera HTTP base URL (for CGI commands)
 * @param presenter   View controller to present player on
 */
- (void)playWithFrontUrl:(NSString *)frontUrl
                 rearUrl:(nullable NSString *)rearUrl
                   title:(nullable NSString *)title
              apiBaseUrl:(nullable NSString *)apiBaseUrl
               presenter:(UIViewController *)presenter;

/** Stop playback and dismiss player */
- (void)stop;

@end

NS_ASSUME_NONNULL_END
