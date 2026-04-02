#import "PlayerViewController.h"

@interface PlayerViewController ()

// Video display
@property (nonatomic, strong) UIView *videoContainer;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *internalDisplayLayer;
@property (nonatomic, assign) BOOL firstFrameRendered;

// Loading / status
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong) UILabel *statusLabel;

// Top bar
@property (nonatomic, strong) UIView *topBar;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *recordingIndicator;
@property (nonatomic, strong) UIView *recordingDot;
@property (nonatomic, strong) UILabel *cameraLabel;

// Bottom controls
@property (nonatomic, strong) UIView *bottomControls;
@property (nonatomic, strong) UIButton *photoButton;
@property (nonatomic, strong) UIButton *recordButton;
@property (nonatomic, strong) UIButton *cameraSwitchBottomButton;

// State
@property (nonatomic, assign) BOOL isRecording;
@property (nonatomic, assign) NSInteger camNum;
@property (nonatomic, strong) NSTimer *blinkTimer;

@end

@implementation PlayerViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor blackColor];
    self.modalPresentationStyle = UIModalPresentationFullScreen;
    
    if (!_currentCamera) _currentCamera = @"front";
    if (!_apiBaseUrl) _apiBaseUrl = @"http://192.168.0.1";
    _camNum = 1;
    
    [self setupUI];
    [self checkCameraCount];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _internalDisplayLayer.frame = _videoContainer.bounds;
    
    CGFloat topInset = 0, bottomInset = 0;
    if (@available(iOS 11.0, *)) {
        topInset = self.view.safeAreaInsets.top;
        bottomInset = self.view.safeAreaInsets.bottom;
    }
    
    _topBar.frame = CGRectMake(0, topInset, self.view.bounds.size.width, 100);
    _bottomControls.frame = CGRectMake(0, self.view.bounds.size.height - 160 - bottomInset,
                                       self.view.bounds.size.width, 160);
    
    // Re-layout gradient layers
    for (CALayer *sub in _topBar.layer.sublayers) {
        if ([sub isKindOfClass:[CAGradientLayer class]]) {
            sub.frame = CGRectMake(0, -topInset, self.view.bounds.size.width * 2, 100 + topInset);
        }
    }
    for (CALayer *sub in _bottomControls.layer.sublayers) {
        if ([sub isKindOfClass:[CAGradientLayer class]]) {
            sub.frame = CGRectMake(0, 0, self.view.bounds.size.width * 2, 160 + bottomInset);
        }
    }
    
    [self updateButtonLayout];
}

- (void)dealloc {
    [_blinkTimer invalidate];
    _blinkTimer = nil;
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

#pragma mark - UI Setup

- (void)setupUI {
    // Video container
    _videoContainer = [[UIView alloc] initWithFrame:self.view.bounds];
    _videoContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _videoContainer.backgroundColor = [UIColor blackColor];
    [self.view addSubview:_videoContainer];
    
    // Display layer for decoded frames
    _internalDisplayLayer = [AVSampleBufferDisplayLayer new];
    _internalDisplayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    _internalDisplayLayer.frame = _videoContainer.bounds;
    _internalDisplayLayer.backgroundColor = [UIColor blackColor].CGColor;
    [_videoContainer.layer addSublayer:_internalDisplayLayer];
    
    // Loading indicator
    if (@available(iOS 13.0, *)) {
        _loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
        _loadingIndicator.color = [UIColor whiteColor];
    } else {
        _loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    }
    _loadingIndicator.center = self.view.center;
    _loadingIndicator.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin |
                                         UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:_loadingIndicator];
    [_loadingIndicator startAnimating];
    
    // Status label
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 280, 60)];
    _statusLabel.center = CGPointMake(self.view.center.x, self.view.center.y + 50);
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin |
                                    UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    _statusLabel.textColor = [UIColor lightGrayColor];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.font = [UIFont systemFontOfSize:14];
    _statusLabel.numberOfLines = 2;
    _statusLabel.text = @"Connecting...";
    [self.view addSubview:_statusLabel];
    
    [self setupTopBar];
    [self setupBottomControls];
}

- (void)setupTopBar {
    _topBar = [[UIView alloc] initWithFrame:CGRectMake(0, 50, self.view.bounds.size.width, 100)];
    _topBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:_topBar];
    
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.frame = CGRectMake(0, -50, self.view.bounds.size.width * 2, 150);
    gradient.colors = @[(id)[UIColor colorWithWhite:0 alpha:0.8].CGColor, (id)[UIColor clearColor].CGColor];
    [_topBar.layer insertSublayer:gradient atIndex:0];
    
    // Close button
    _backButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _backButton.frame = CGRectMake(16, 0, 44, 44);
    [self setCloseIconForButton:_backButton];
    [_backButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [_topBar addSubview:_backButton];
    
    // Title
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(60, 0, self.view.bounds.size.width - 120, 44)];
    _titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _titleLabel.text = _titleText ?: @"Live Stream";
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.font = [UIFont boldSystemFontOfSize:18];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    [_topBar addSubview:_titleLabel];
    
    // Recording indicator (REC dot + label)
    _recordingIndicator = [[UIView alloc] initWithFrame:CGRectMake(self.view.bounds.size.width - 80, 10, 70, 24)];
    _recordingIndicator.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    _recordingIndicator.hidden = YES;
    [_topBar addSubview:_recordingIndicator];
    
    _recordingDot = [[UIView alloc] initWithFrame:CGRectMake(0, 6, 12, 12)];
    _recordingDot.backgroundColor = [UIColor redColor];
    _recordingDot.layer.cornerRadius = 6;
    [_recordingIndicator addSubview:_recordingDot];
    
    UILabel *recLabel = [[UILabel alloc] initWithFrame:CGRectMake(18, 0, 50, 24)];
    recLabel.text = @"REC";
    recLabel.textColor = [UIColor redColor];
    recLabel.font = [UIFont boldSystemFontOfSize:14];
    [_recordingIndicator addSubview:recLabel];
    
    // Camera label (top-right, hidden until camnum >= 2)
    _cameraLabel = [[UILabel alloc] initWithFrame:CGRectMake(self.view.bounds.size.width - 100, 50, 80, 36)];
    _cameraLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    _cameraLabel.text = @"Front";
    _cameraLabel.textColor = [UIColor whiteColor];
    _cameraLabel.textAlignment = NSTextAlignmentCenter;
    _cameraLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _cameraLabel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
    _cameraLabel.layer.cornerRadius = 18;
    _cameraLabel.clipsToBounds = YES;
    _cameraLabel.hidden = YES;
    [_topBar addSubview:_cameraLabel];
}

- (void)setupBottomControls {
    _bottomControls = [[UIView alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height - 160,
                                                                self.view.bounds.size.width, 160)];
    _bottomControls.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:_bottomControls];
    
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.frame = CGRectMake(0, 0, self.view.bounds.size.width * 2, 160);
    gradient.colors = @[(id)[UIColor clearColor].CGColor, (id)[UIColor colorWithWhite:0 alpha:0.8].CGColor];
    [_bottomControls.layer insertSublayer:gradient atIndex:0];
    
    CGFloat centerX = self.view.bounds.size.width / 2;
    CGFloat buttonSize = 60;
    CGFloat spacing = 90;
    
    // Photo button
    _photoButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _photoButton.frame = CGRectMake(centerX - spacing - buttonSize/2, 40, buttonSize, buttonSize);
    _photoButton.backgroundColor = [UIColor whiteColor];
    _photoButton.layer.cornerRadius = buttonSize / 2;
    [self setPhotoIconForButton:_photoButton];
    [_photoButton addTarget:self action:@selector(takePhoto) forControlEvents:UIControlEventTouchUpInside];
    [_bottomControls addSubview:_photoButton];
    
    // Record button
    _recordButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _recordButton.frame = CGRectMake(centerX - buttonSize/2, 40, buttonSize, buttonSize);
    _recordButton.backgroundColor = [UIColor whiteColor];
    _recordButton.layer.cornerRadius = buttonSize / 2;
    [self setRecordIconForButton:_recordButton];
    [_recordButton addTarget:self action:@selector(toggleRecording) forControlEvents:UIControlEventTouchUpInside];
    [_bottomControls addSubview:_recordButton];
    
    // Camera switch button (hidden until camnum >= 2)
    _cameraSwitchBottomButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _cameraSwitchBottomButton.frame = CGRectMake(centerX + spacing - buttonSize/2, 40, buttonSize, buttonSize);
    _cameraSwitchBottomButton.backgroundColor = [UIColor whiteColor];
    _cameraSwitchBottomButton.layer.cornerRadius = buttonSize / 2;
    [self setCameraSwitchIconForButton:_cameraSwitchBottomButton];
    [_cameraSwitchBottomButton addTarget:self action:@selector(switchCamera) forControlEvents:UIControlEventTouchUpInside];
    _cameraSwitchBottomButton.hidden = YES;
    [_bottomControls addSubview:_cameraSwitchBottomButton];
}

- (void)updateButtonLayout {
    CGFloat centerX = self.view.bounds.size.width / 2;
    CGFloat buttonSize = 60;
    CGFloat spacing = 90;
    
    _photoButton.frame = CGRectMake(centerX - spacing - buttonSize/2, 40, buttonSize, buttonSize);
    _recordButton.frame = CGRectMake(centerX - buttonSize/2, 40, buttonSize, buttonSize);
    _cameraSwitchBottomButton.frame = CGRectMake(centerX + spacing - buttonSize/2, 40, buttonSize, buttonSize);
}

#pragma mark - SVG Icons

- (void)setCloseIconForButton:(UIButton *)button {
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(34.9, 27)];
    [path addLineToPoint:CGPointMake(52.4, 9.5)];
    [path addCurveToPoint:CGPointMake(52.4, 1.7) controlPoint1:CGPointMake(54.6, 7.3) controlPoint2:CGPointMake(54.6, 3.9)];
    [path addCurveToPoint:CGPointMake(44.6, 1.7) controlPoint1:CGPointMake(50.2, -0.5) controlPoint2:CGPointMake(46.8, -0.5)];
    [path addLineToPoint:CGPointMake(27.1, 19.2)];
    [path addLineToPoint:CGPointMake(9.4, 1.6)];
    [path addCurveToPoint:CGPointMake(1.6, 1.6) controlPoint1:CGPointMake(7.2, -0.6) controlPoint2:CGPointMake(3.8, -0.6)];
    [path addCurveToPoint:CGPointMake(1.6, 9.4) controlPoint1:CGPointMake(-0.6, 3.8) controlPoint2:CGPointMake(-0.5, 7.1)];
    [path addLineToPoint:CGPointMake(19.3, 27)];
    [path addLineToPoint:CGPointMake(1.8, 44.5)];
    [path addCurveToPoint:CGPointMake(1.8, 52.3) controlPoint1:CGPointMake(-0.4, 46.7) controlPoint2:CGPointMake(-0.4, 50.1)];
    [path addCurveToPoint:CGPointMake(5.7, 54) controlPoint1:CGPointMake(2.8, 53.5) controlPoint2:CGPointMake(4.3, 54)];
    [path addCurveToPoint:CGPointMake(9.6, 52.4) controlPoint1:CGPointMake(7.1, 54) controlPoint2:CGPointMake(8.5, 53.5)];
    [path addLineToPoint:CGPointMake(27.1, 34.9)];
    [path addLineToPoint:CGPointMake(44.6, 52.4)];
    [path addCurveToPoint:CGPointMake(48.5, 54) controlPoint1:CGPointMake(45.7, 53.5) controlPoint2:CGPointMake(47, 54)];
    [path addCurveToPoint:CGPointMake(52.4, 52.4) controlPoint1:CGPointMake(49.9, 54) controlPoint2:CGPointMake(51.3, 53.5)];
    [path addCurveToPoint:CGPointMake(52.4, 44.6) controlPoint1:CGPointMake(54.6, 50.2) controlPoint2:CGPointMake(54.6, 46.8)];
    [path addLineToPoint:CGPointMake(34.9, 27)];
    [path closePath];
    
    CAShapeLayer *shapeLayer = [CAShapeLayer layer];
    CGFloat scale = 24.0 / 64.0;
    CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
    shapeLayer.path = CGPathCreateCopyByTransformingPath(path.CGPath, &transform);
    shapeLayer.fillColor = [UIColor whiteColor].CGColor;
    shapeLayer.frame = CGRectMake(10, 10, 24, 24);
    [button.layer addSublayer:shapeLayer];
}

- (void)setPhotoIconForButton:(UIButton *)button {
    UIBezierPath *path = [UIBezierPath bezierPath];
    // Camera body
    [path moveToPoint:CGPointMake(26.9, 48.6)];
    [path addLineToPoint:CGPointMake(5.5, 48.6)];
    [path addCurveToPoint:CGPointMake(0.7, 45.9) controlPoint1:CGPointMake(3.4, 48.6) controlPoint2:CGPointMake(1.6, 47.7)];
    [path addCurveToPoint:CGPointMake(0, 43.2) controlPoint1:CGPointMake(0.3, 45.1) controlPoint2:CGPointMake(0, 44.2)];
    [path addCurveToPoint:CGPointMake(0, 18.9) controlPoint1:CGPointMake(0, 35.1) controlPoint2:CGPointMake(0, 27)];
    [path addCurveToPoint:CGPointMake(5.3, 13.5) controlPoint1:CGPointMake(0, 15.8) controlPoint2:CGPointMake(2.2, 13.5)];
    [path addLineToPoint:CGPointMake(10.9, 13.5)];
    [path addCurveToPoint:CGPointMake(14.2, 11.1) controlPoint1:CGPointMake(12.8, 13.5) controlPoint2:CGPointMake(13.4, 13.1)];
    [path addLineToPoint:CGPointMake(15.5, 7.1)];
    [path addCurveToPoint:CGPointMake(18, 5.4) controlPoint1:CGPointMake(16, 5.9) controlPoint2:CGPointMake(16.8, 5.4)];
    [path addLineToPoint:CGPointMake(35.9, 5.4)];
    [path addCurveToPoint:CGPointMake(38.4, 7.2) controlPoint1:CGPointMake(37.2, 5.4) controlPoint2:CGPointMake(38, 6)];
    [path addLineToPoint:CGPointMake(39.8, 11.5)];
    [path addCurveToPoint:CGPointMake(42.6, 13.5) controlPoint1:CGPointMake(40.3, 13) controlPoint2:CGPointMake(41.4, 13.5)];
    [path addLineToPoint:CGPointMake(48.2, 13.5)];
    [path addCurveToPoint:CGPointMake(54, 19.2) controlPoint1:CGPointMake(51.6, 13.4) controlPoint2:CGPointMake(53.8, 16.5)];
    [path addCurveToPoint:CGPointMake(54, 43.2) controlPoint1:CGPointMake(53.9, 27.2) controlPoint2:CGPointMake(53.9, 35.2)];
    [path addCurveToPoint:CGPointMake(48.5, 48.7) controlPoint1:CGPointMake(54, 45.9) controlPoint2:CGPointMake(51.2, 48.7)];
    [path addLineToPoint:CGPointMake(26.9, 48.6)];
    [path closePath];
    // Lens circle
    [path moveToPoint:CGPointMake(27, 16.2)];
    [path addCurveToPoint:CGPointMake(13.4, 29.7) controlPoint1:CGPointMake(19.5, 16.2) controlPoint2:CGPointMake(13.4, 22.2)];
    [path addCurveToPoint:CGPointMake(26.9, 43.3) controlPoint1:CGPointMake(13.4, 37.2) controlPoint2:CGPointMake(19.4, 43.3)];
    [path addCurveToPoint:CGPointMake(40.5, 29.8) controlPoint1:CGPointMake(34.4, 43.3) controlPoint2:CGPointMake(40.5, 37.3)];
    [path addCurveToPoint:CGPointMake(27, 16.2) controlPoint1:CGPointMake(40.5, 22.3) controlPoint2:CGPointMake(34.5, 16.2)];
    [path closePath];
    // Inner lens
    [path moveToPoint:CGPointMake(27, 37.8)];
    [path addCurveToPoint:CGPointMake(18.9, 29.7) controlPoint1:CGPointMake(22.5, 37.8) controlPoint2:CGPointMake(18.9, 34.2)];
    [path addCurveToPoint:CGPointMake(27, 21.6) controlPoint1:CGPointMake(18.9, 25.2) controlPoint2:CGPointMake(22.5, 21.6)];
    [path addCurveToPoint:CGPointMake(35.1, 29.7) controlPoint1:CGPointMake(31.5, 21.6) controlPoint2:CGPointMake(35.1, 25.2)];
    [path addCurveToPoint:CGPointMake(27, 37.8) controlPoint1:CGPointMake(35.1, 34.2) controlPoint2:CGPointMake(31.5, 37.8)];
    [path closePath];
    
    CAShapeLayer *shapeLayer = [CAShapeLayer layer];
    CGFloat scale = 30.0 / 54.0;
    CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
    shapeLayer.path = CGPathCreateCopyByTransformingPath(path.CGPath, &transform);
    shapeLayer.fillColor = [UIColor blackColor].CGColor;
    shapeLayer.frame = CGRectMake(15, 15, 30, 30);
    [button.layer addSublayer:shapeLayer];
}

- (void)setRecordIconForButton:(UIButton *)button {
    UIBezierPath *path = [UIBezierPath bezierPath];
    // Video camera body
    [path moveToPoint:CGPointMake(42.7, 31.2)];
    [path addCurveToPoint:CGPointMake(49.5, 25.3) controlPoint1:CGPointMake(45.3, 28.8) controlPoint2:CGPointMake(47.2, 26.9)];
    [path addCurveToPoint:CGPointMake(52.9, 24.5) controlPoint1:CGPointMake(50.4, 24.7) controlPoint2:CGPointMake(51.9, 24.4)];
    [path addCurveToPoint:CGPointMake(53.9, 27.2) controlPoint1:CGPointMake(53.4, 24.6) controlPoint2:CGPointMake(53.9, 25.9)];
    [path addCurveToPoint:CGPointMake(53.9, 46.5) controlPoint1:CGPointMake(54, 33.6) controlPoint2:CGPointMake(54, 40.1)];
    [path addCurveToPoint:CGPointMake(52.4, 49.6) controlPoint1:CGPointMake(53.9, 47.6) controlPoint2:CGPointMake(53.1, 49.4)];
    [path addCurveToPoint:CGPointMake(48.8, 48.7) controlPoint1:CGPointMake(51.4, 49.9) controlPoint2:CGPointMake(50.4, 49.5)];
    [path addLineToPoint:CGPointMake(42.7, 42.6)];
    [path addLineToPoint:CGPointMake(42.7, 46.6)];
    [path addCurveToPoint:CGPointMake(37.3, 52) controlPoint1:CGPointMake(42.6, 50.6) controlPoint2:CGPointMake(40.0, 52)];
    [path addLineToPoint:CGPointMake(10.6, 52)];
    [path addLineToPoint:CGPointMake(4.7, 52)];
    [path addCurveToPoint:CGPointMake(0.1, 47.2) controlPoint1:CGPointMake(1.4, 51.9) controlPoint2:CGPointMake(0.0, 50.3)];
    [path addCurveToPoint:CGPointMake(0.1, 27) controlPoint1:CGPointMake(0, 40.4) controlPoint2:CGPointMake(0.1, 33.8)];
    [path addCurveToPoint:CGPointMake(4.4, 22.1) controlPoint1:CGPointMake(0.1, 23.9) controlPoint2:CGPointMake(1.3, 22.1)];
    [path addLineToPoint:CGPointMake(38.6, 22.1)];
    [path addCurveToPoint:CGPointMake(42.8, 26.5) controlPoint1:CGPointMake(41.3, 22.1) controlPoint2:CGPointMake(42.7, 23.8)];
    [path addLineToPoint:CGPointMake(42.7, 31.2)];
    [path closePath];
    // Top left circle
    [path moveToPoint:CGPointMake(9.7, 20.1)];
    [path addCurveToPoint:CGPointMake(0, 11.1) controlPoint1:CGPointMake(4.3, 20.1) controlPoint2:CGPointMake(0, 16.3)];
    [path addCurveToPoint:CGPointMake(9.9, 2) controlPoint1:CGPointMake(0, 5.9) controlPoint2:CGPointMake(4.7, 1.9)];
    [path addCurveToPoint:CGPointMake(19.4, 11) controlPoint1:CGPointMake(15.1, 2.1) controlPoint2:CGPointMake(19.4, 6.2)];
    [path addCurveToPoint:CGPointMake(9.7, 20.1) controlPoint1:CGPointMake(19.5, 16.1) controlPoint2:CGPointMake(15.1, 20.2)];
    [path closePath];
    // Top right circle
    [path moveToPoint:CGPointMake(40.4, 11.2)];
    [path addCurveToPoint:CGPointMake(30.7, 20.2) controlPoint1:CGPointMake(40.4, 16.2) controlPoint2:CGPointMake(36.0, 20.2)];
    [path addCurveToPoint:CGPointMake(20.9, 11.2) controlPoint1:CGPointMake(25.4, 20.2) controlPoint2:CGPointMake(20.9, 16.2)];
    [path addCurveToPoint:CGPointMake(30.6, 2.1) controlPoint1:CGPointMake(20.9, 6.3) controlPoint2:CGPointMake(25.3, 2.1)];
    [path addCurveToPoint:CGPointMake(40.4, 11.2) controlPoint1:CGPointMake(36.0, 2.1) controlPoint2:CGPointMake(40.4, 6.2)];
    [path closePath];
    
    CAShapeLayer *shapeLayer = [CAShapeLayer layer];
    CGFloat scale = 30.0 / 54.0;
    CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
    shapeLayer.path = CGPathCreateCopyByTransformingPath(path.CGPath, &transform);
    shapeLayer.fillColor = [UIColor blackColor].CGColor;
    shapeLayer.frame = CGRectMake(15, 15, 30, 30);
    [button.layer addSublayer:shapeLayer];
}

- (void)setCameraSwitchIconForButton:(UIButton *)button {
    UIBezierPath *path = [UIBezierPath bezierPath];
    path.usesEvenOddFillRule = YES;
    // Camera body
    [path moveToPoint:CGPointMake(26.9, 48.6)];
    [path addLineToPoint:CGPointMake(5.5, 48.6)];
    [path addCurveToPoint:CGPointMake(0.7, 45.9) controlPoint1:CGPointMake(3.4, 48.6) controlPoint2:CGPointMake(1.6, 47.7)];
    [path addCurveToPoint:CGPointMake(0, 43.2) controlPoint1:CGPointMake(0.3, 45.1) controlPoint2:CGPointMake(0, 44.2)];
    [path addCurveToPoint:CGPointMake(0, 18.9) controlPoint1:CGPointMake(0, 35.1) controlPoint2:CGPointMake(0, 27)];
    [path addCurveToPoint:CGPointMake(5.3, 13.5) controlPoint1:CGPointMake(0, 15.8) controlPoint2:CGPointMake(2.2, 13.5)];
    [path addLineToPoint:CGPointMake(10.9, 13.5)];
    [path addCurveToPoint:CGPointMake(14.2, 11.1) controlPoint1:CGPointMake(12.8, 13.5) controlPoint2:CGPointMake(13.4, 13.1)];
    [path addLineToPoint:CGPointMake(15.5, 7.1)];
    [path addCurveToPoint:CGPointMake(18, 5.4) controlPoint1:CGPointMake(16, 5.9) controlPoint2:CGPointMake(16.8, 5.4)];
    [path addLineToPoint:CGPointMake(35.9, 5.4)];
    [path addCurveToPoint:CGPointMake(38.4, 7.2) controlPoint1:CGPointMake(37.2, 5.4) controlPoint2:CGPointMake(38, 6)];
    [path addLineToPoint:CGPointMake(39.8, 11.5)];
    [path addCurveToPoint:CGPointMake(42.6, 13.5) controlPoint1:CGPointMake(40.3, 13) controlPoint2:CGPointMake(41.4, 13.5)];
    [path addLineToPoint:CGPointMake(48.2, 13.5)];
    [path addCurveToPoint:CGPointMake(54, 19.2) controlPoint1:CGPointMake(51.6, 13.4) controlPoint2:CGPointMake(53.8, 16.5)];
    [path addCurveToPoint:CGPointMake(54, 43.2) controlPoint1:CGPointMake(53.9, 27.2) controlPoint2:CGPointMake(53.9, 35.2)];
    [path addCurveToPoint:CGPointMake(48.5, 48.7) controlPoint1:CGPointMake(54, 45.9) controlPoint2:CGPointMake(51.2, 48.7)];
    [path addLineToPoint:CGPointMake(26.9, 48.6)];
    [path closePath];
    // Arrow arcs
    [path moveToPoint:CGPointMake(19.5, 24.8)];
    [path addCurveToPoint:CGPointMake(35.6, 26.9) controlPoint1:CGPointMake(24.6, 17.8) controlPoint2:CGPointMake(32.2, 18.8)];
    [path addLineToPoint:CGPointMake(32.5, 28.0)];
    [path addCurveToPoint:CGPointMake(22.2, 26.6) controlPoint1:CGPointMake(29.5, 22.0) controlPoint2:CGPointMake(25.2, 21.5)];
    [path closePath];
    [path moveToPoint:CGPointMake(34.5, 29.7)];
    [path addLineToPoint:CGPointMake(37.4, 25.6)];
    [path addLineToPoint:CGPointMake(30.4, 28.6)];
    [path closePath];
    [path moveToPoint:CGPointMake(34.5, 35.2)];
    [path addCurveToPoint:CGPointMake(18.4, 33.1) controlPoint1:CGPointMake(29.4, 42.2) controlPoint2:CGPointMake(21.8, 41.2)];
    [path addLineToPoint:CGPointMake(21.5, 32.0)];
    [path addCurveToPoint:CGPointMake(31.8, 33.4) controlPoint1:CGPointMake(24.5, 38.0) controlPoint2:CGPointMake(28.8, 38.5)];
    [path closePath];
    [path moveToPoint:CGPointMake(19.5, 30.3)];
    [path addLineToPoint:CGPointMake(16.6, 34.4)];
    [path addLineToPoint:CGPointMake(23.6, 31.4)];
    [path closePath];
    
    CAShapeLayer *shapeLayer = [CAShapeLayer layer];
    CGFloat scale = 30.0 / 54.0;
    CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
    shapeLayer.path = CGPathCreateCopyByTransformingPath(path.CGPath, &transform);
    shapeLayer.fillColor = [UIColor blackColor].CGColor;
    shapeLayer.fillRule = kCAFillRuleEvenOdd;
    shapeLayer.frame = CGRectMake(15, 15, 30, 30);
    [button.layer addSublayer:shapeLayer];
}

#pragma mark - Public: Display Layer

- (AVSampleBufferDisplayLayer *)displayLayer {
    return _internalDisplayLayer;
}

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!_internalDisplayLayer) return;
    
    // Flush if display layer errored
    if (_internalDisplayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        NSLog(@"[PlayerVC] Display layer failed: %@, flushing", _internalDisplayLayer.error);
        [_internalDisplayLayer flush];
    }
    
    [_internalDisplayLayer enqueueSampleBuffer:sampleBuffer];
    
    // Hide loading UI on first frame
    if (!_firstFrameRendered) {
        _firstFrameRendered = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimating];
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

#pragma mark - Public: State Updates

- (void)setRecordingState:(BOOL)recording {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.isRecording = recording;
        self.recordingIndicator.hidden = !recording;
        self.recordButton.backgroundColor = recording ? [UIColor redColor] : [UIColor whiteColor];
        
        if (recording) {
            [self.blinkTimer invalidate];
            self.blinkTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
                self.recordingDot.alpha = self.recordingDot.alpha > 0.5 ? 0.3 : 1.0;
            }];
        } else {
            [self.blinkTimer invalidate];
            self.blinkTimer = nil;
            self.recordingDot.alpha = 1.0;
        }
    });
}

- (void)setCameraCount:(NSInteger)count {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.camNum = count;
        if (count >= 2) {
            self.cameraSwitchBottomButton.hidden = NO;
            self.cameraLabel.hidden = NO;
        }
    });
}

#pragma mark - Camera Count Check

- (void)checkCameraCount {
    NSString *urlStr = [NSString stringWithFormat:@"%@/cgi-bin/hisnet/getcamnum.cgi", _apiBaseUrl];
    NSURL *url = [NSURL URLWithString:urlStr];
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url
                                                             completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) return;
        
        NSString *responseText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSLog(@"[PlayerVC] Camera count response: %@", responseText);
        
        // Parse: var camnum="2";
        NSRange range = [responseText rangeOfString:@"camnum=\""];
        if (range.location != NSNotFound) {
            NSUInteger startIdx = range.location + range.length;
            NSRange endRange = [responseText rangeOfString:@"\"" options:0 range:NSMakeRange(startIdx, responseText.length - startIdx)];
            if (endRange.location != NSNotFound) {
                NSString *numStr = [responseText substringWithRange:NSMakeRange(startIdx, endRange.location - startIdx)];
                NSInteger num = [numStr integerValue];
                [self setCameraCount:num];
            }
        }
    }];
    [task resume];
}

#pragma mark - Actions

- (void)closeTapped {
    [_blinkTimer invalidate];
    _blinkTimer = nil;
    [self.delegate playerViewControllerDidClose];
}

- (void)takePhoto {
    [self showToast:@"Taking photo..."];
    [self.delegate playerViewControllerDidRequestPhoto];
    
    [self sendCameraCommand:@"trigger" success:^{
        [self showToast:@"Photo saved!"];
    } failure:^{
        [self showToast:@"Photo failed"];
    }];
}

- (void)toggleRecording {
    BOOL start = !_isRecording;
    [self showToast:start ? @"Starting..." : @"Stopping..."];
    
    [self sendCameraCommand:start ? @"start" : @"stop" success:^{
        [self setRecordingState:start];
        [self showToast:start ? @"Recording" : @"Stopped"];
        [self.delegate playerViewControllerDidRequestRecordToggle];
    } failure:^{
        [self showToast:@"Failed"];
    }];
}

- (void)switchCamera {
    _currentCamera = [_currentCamera isEqualToString:@"front"] ? @"rear" : @"front";
    _cameraLabel.text = [_currentCamera isEqualToString:@"front"] ? @"Front" : @"Rear";
    
    [self showToast:@"Switching camera..."];
    
    // Reset display for new stream
    _firstFrameRendered = NO;
    [_loadingIndicator startAnimating];
    _statusLabel.text = @"Switching camera...";
    _statusLabel.alpha = 1;
    [_internalDisplayLayer flush];
    
    [self.delegate playerViewControllerDidRequestCameraSwitch];
}

#pragma mark - Camera HTTP API

- (void)sendCameraCommand:(NSString *)cmd success:(void(^)(void))success failure:(void(^)(void))failure {
    NSString *urlStr = [NSString stringWithFormat:@"%@/cgi-bin/hisnet/workmodecmd.cgi?-cmd=%@", _apiBaseUrl, cmd];
    NSURL *url = [NSURL URLWithString:urlStr];
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url
                                                             completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)r;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (http.statusCode >= 200 && http.statusCode < 300 && !e) {
                if (success) success();
            } else {
                if (failure) failure();
            }
        });
    }];
    [task resume];
}

#pragma mark - Toast

- (void)showToast:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        UILabel *toast = [[UILabel alloc] init];
        toast.text = [NSString stringWithFormat:@"  %@  ", msg];
        toast.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
        toast.textColor = [UIColor whiteColor];
        toast.textAlignment = NSTextAlignmentCenter;
        toast.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        toast.layer.cornerRadius = 8;
        toast.clipsToBounds = YES;
        toast.alpha = 0;
        [toast sizeToFit];
        toast.frame = CGRectMake((self.view.bounds.size.width - toast.bounds.size.width - 32) / 2,
                                 self.view.bounds.size.height - 220,
                                 toast.bounds.size.width + 32, 40);
        [self.view addSubview:toast];
        
        [UIView animateWithDuration:0.2 animations:^{ toast.alpha = 1; } completion:^(BOOL f) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.2 animations:^{ toast.alpha = 0; } completion:^(BOOL f) {
                    [toast removeFromSuperview];
                }];
            });
        }];
    });
}

@end
