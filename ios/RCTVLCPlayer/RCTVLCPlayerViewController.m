#import "RCTVLCPlayerViewController.h"

@interface RCTVLCPlayerViewController ()
@property(nonatomic, strong) UIView *videoView;
@end

@implementation RCTVLCPlayerViewController

- (void)viewDidLoad {
  [super viewDidLoad];

  // 初始化视频输出视图
  _videoView = [[UIView alloc] init];
  _videoView.backgroundColor = [UIColor blackColor];
  _videoView.userInteractionEnabled = NO;
  _videoView.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:_videoView];

  // 设置视频输出视图的约束
  [NSLayoutConstraint activateConstraints:@[
    [_videoView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [_videoView.trailingAnchor
        constraintEqualToAnchor:self.view.trailingAnchor],
    [_videoView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
    [_videoView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
  ]];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  // 确保视频输出视图随父视图大小变化
  _videoView.frame = self.view.bounds;
}

- (UIScreen *)currentScreen {
  for (UIWindowScene *windowScene in [UIApplication sharedApplication]
           .connectedScenes) {
    if (windowScene.activationState == UISceneActivationStateForegroundActive) {
      return windowScene.screen;
    }
  }
  return [UIScreen mainScreen];
}

- (void)setResizeMode:(NSString *)resizeMode {
  // 存储传入的 resizeMode 值
  _resizeMode = resizeMode;

  if (!_player) {
    return;
  }

  if ([resizeMode isEqualToString:@"cover"]) {
    UIScreen *screen = [self currentScreen];
    CGSize screenSize = screen.bounds.size;
    [self fillScreenWithScreenSize:screenSize];
  } else {
    [UIView animateWithDuration:0.2
                     animations:^{
                       self.videoView.transform = CGAffineTransformIdentity;
                     }];
    _player.videoAspectRatio = NULL;
  }
}

- (void)fillScreenWithScreenSize:(CGSize)screenSize {
  if (!_player) {
    return;
  }
  // 获取视频的原始尺寸
  CGSize videoSize = _player.videoSize;

  // 计算按比例填充屏幕的尺寸
  CGSize fillSize = [self aspectFillWithAspectRatio:videoSize
                                        minimumSize:screenSize];

  // 计算缩放比例
  CGFloat scale;
  if (fillSize.height > screenSize.height) {
    scale = fillSize.height / screenSize.height;
  } else {
    scale = fillSize.width / screenSize.width;
  }

  // 使用动画应用缩放变换
  [UIView animateWithDuration:0.2
                   animations:^{
                     self.videoView.transform =
                         CGAffineTransformMakeScale(scale, scale);
                   }];

  // 重置视频宽高比（根据你的逻辑）
  _player.videoAspectRatio = NULL;
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:
           (id<UIViewControllerTransitionCoordinator>)coordinator {
  if ([_resizeMode isEqualToString:@"cover"]) {
    [self fillScreenWithScreenSize:size];
  }
  [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}

- (CGSize)aspectFillWithAspectRatio:(CGSize)aspectRatio
                        minimumSize:(CGSize)minimumSize {
  CGFloat aspectWidth = aspectRatio.width;
  CGFloat aspectHeight = aspectRatio.height;
  CGFloat minWidth = minimumSize.width;
  CGFloat minHeight = minimumSize.height;

  // 计算宽高比
  CGFloat ratio = aspectWidth / aspectHeight;
  CGFloat minRatio = minWidth / minHeight;

  CGSize resultSize;

  // 如果视频的宽高比大于屏幕的宽高比，基于高度计算宽度（裁剪左右两侧）
  if (ratio > minRatio) {
    resultSize.height = minHeight;
    resultSize.width = minHeight * ratio;
  }
  // 如果视频的宽高比小于屏幕的宽高比，基于宽度计算高度（裁剪上下两侧）
  else {
    resultSize.width = minWidth;
    resultSize.height = minWidth / ratio;
  }

  return resultSize;
}

@end