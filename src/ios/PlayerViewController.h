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
 * Phase 1: minimal stub — shows black screen with Close button.
 * Phase 4-5: full UI with camera controls.
 */
@interface PlayerViewController : UIViewController

@property (nonatomic, weak) id<PlayerViewControllerDelegate> delegate;
@property (nonatomic, copy, nullable) NSString *titleText;

/** Get the display layer for rendering frames (Phase 3+) */
@property (nonatomic, readonly) AVSampleBufferDisplayLayer *displayLayer;

/** Update status label (e.g. "Connecting...", "Playing") */
- (void)setStatusText:(NSString *)text;

/** Enqueue a decoded CMSampleBuffer for rendering on the display layer */
- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer;

@end

NS_ASSUME_NONNULL_END
