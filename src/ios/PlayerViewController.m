#import "PlayerViewController.h"

@interface PlayerViewController ()
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *internalDisplayLayer;
@property (nonatomic, assign) BOOL firstFrameRendered;
@end

@implementation PlayerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor blackColor];
    self.modalPresentationStyle = UIModalPresentationFullScreen;
    
    // Display layer for decoded frames
    _internalDisplayLayer = [AVSampleBufferDisplayLayer new];
    _internalDisplayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    _internalDisplayLayer.frame = self.view.bounds;
    _internalDisplayLayer.backgroundColor = [UIColor blackColor].CGColor;
    [self.view.layer addSublayer:_internalDisplayLayer];
    
    // Status label (shown until first frame)
    _statusLabel = [[UILabel alloc] init];
    _statusLabel.textColor = [UIColor whiteColor];
    _statusLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.text = @"Connecting...";
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_statusLabel];
    
    // Close button
    _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_closeButton setTitle:@"✕" forState:UIControlStateNormal];
    [_closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _closeButton.titleLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    _closeButton.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
    _closeButton.layer.cornerRadius = 20;
    [_closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    _closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_closeButton];
    
    [NSLayoutConstraint activateConstraints:@[
        [_statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_statusLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        
        [_closeButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [_closeButton.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [_closeButton.widthAnchor constraintEqualToConstant:40],
        [_closeButton.heightAnchor constraintEqualToConstant:40],
    ]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _internalDisplayLayer.frame = self.view.bounds;
}

- (AVSampleBufferDisplayLayer *)displayLayer {
    return _internalDisplayLayer;
}

/**
 * Enqueue a decoded frame for display.
 * Hides the status label on first frame.
 */
- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!_internalDisplayLayer) return;
    
    // Check layer status — flush if error
    if (_internalDisplayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        NSLog(@"[PlayerVC] Display layer failed: %@, flushing", _internalDisplayLayer.error);
        [_internalDisplayLayer flush];
    }
    
    [_internalDisplayLayer enqueueSampleBuffer:sampleBuffer];
    
    // Hide status label after first rendered frame
    if (!_firstFrameRendered) {
        _firstFrameRendered = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                self.statusLabel.alpha = 0;
            }];
        });
    }
}

- (void)setStatusText:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = text;
        if (!self.firstFrameRendered) {
            self.statusLabel.alpha = 1;
        }
    });
}

- (void)closeTapped {
    [self.delegate playerViewControllerDidClose];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

@end
