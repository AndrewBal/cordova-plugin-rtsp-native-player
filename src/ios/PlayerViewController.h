#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol PlayerViewControllerDelegate <NSObject>
- (void)playerViewControllerDidClose;
- (void)playerViewControllerDidRequestPhoto;
- (void)playerViewControllerDidRequestRecordToggle;
- (void)playerViewControllerDidRequestCameraSwitch;
@end

/**
 * PlayerViewController
 *
 * Full-screen video player with overlay controls.
 * Uses AVSampleBufferDisplayLayer to render decoded H.264 frames.
 *
 * UI matches the HlsPlayerViewController design:
 * - Top bar: close button, title, REC indicator, camera label
 * - Bottom bar: photo, record, camera switch buttons
 * - Toast notifications for user feedback
 */
@interface PlayerViewController : UIViewController

@property (nonatomic, weak) id<PlayerViewControllerDelegate> delegate;
@property (nonatomic, copy, nullable) NSString *titleText;
@property (nonatomic, copy, nullable) NSString *apiBaseUrl;
@property (nonatomic, copy, nullable) NSString *currentCamera;  // "front" or "rear"

/** Get the display layer for rendering frames */
@property (nonatomic, readonly) AVSampleBufferDisplayLayer *displayLayer;

/** Update status label (e.g. "Connecting...", "Playing") */
- (void)setStatusText:(NSString *)text;

/** Enqueue a decoded CMSampleBuffer for rendering on the display layer */
- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer;

/** Show a toast message */
- (void)showToast:(NSString *)msg;

/** Update recording state (updates UI: button color, REC indicator) */
- (void)setRecordingState:(BOOL)recording;

/** Show/hide camera switch button based on camera count */
- (void)setCameraCount:(NSInteger)count;

@end

NS_ASSUME_NONNULL_END
