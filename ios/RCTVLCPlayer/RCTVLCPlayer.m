#import "RCTVLCPlayer.h"
#import "React/RCTBridgeModule.h"
#import "React/RCTConvert.h"
#import "React/RCTEventDispatcher.h"
#import "React/UIView+React.h"
#import <UIKit/UIKit.h>
#if TARGET_OS_TV
#import <TVVLCKit/TVVLCKit.h>
#else
#import <MobileVLCKit/MobileVLCKit.h>
#endif
#import <AVFoundation/AVFoundation.h>

static NSString *const statusKeyPath = @"status";
static NSString *const playbackLikelyToKeepUpKeyPath =
    @"playbackLikelyToKeepUp";
static NSString *const playbackBufferEmptyKeyPath = @"playbackBufferEmpty";
static NSString *const readyForDisplayKeyPath = @"readyForDisplay";
static NSString *const playbackRate = @"rate";

#if !defined(DEBUG) || !(TARGET_IPHONE_SIMULATOR)
#define NSLog(...)
#endif

@implementation RCTVLCPlayer {

  /* Required to publish events */
  RCTEventDispatcher *_eventDispatcher;
  VLCMediaPlayer *_player;

  NSDictionary *_videoInfo;
  NSString *_subtitleUri;

  BOOL _paused;
  BOOL _autoplay;
  BOOL _repeat;
  BOOL _isFullscreen;
  BOOL _isLandscape; // 新增变量，用于跟踪当前是否为横屏状态
  BOOL _isUpdatingLayout; // 新增变量，防止layoutSubviews中的无限循环

  NSString *_resizeMode;
  UIView *_originalParentView;
  CGRect _originalFrame;
}

- (instancetype)initWithEventDispatcher:(RCTEventDispatcher *)eventDispatcher {
  if ((self = [super init])) {
    _eventDispatcher = eventDispatcher;

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(applicationWillResignActive:)
               name:UIApplicationWillResignActiveNotification
             object:nil];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(applicationWillEnterForeground:)
               name:UIApplicationWillEnterForegroundNotification
             object:nil];

    // 添加方向变化监听
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(orientationDidChange:)
               name:UIDeviceOrientationDidChangeNotification
             object:nil];
  }

  return self;
}

- (void)applicationWillEnterForeground:(NSNotification *)notification {
  if (!_paused)
    [self play];
}

- (void)applicationWillResignActive:(NSNotification *)notification {
  if (!_paused)
    [self play];
}

- (void)play {
  if (_player) {

    [_player play];
    _paused = NO;
  }
}

- (void)pause {
  if (_player) {
    [_player pause];
    _paused = YES;
  }
}

- (void)setSource:(NSDictionary *)source {
  if (_player) {
    [self _release];
  }

  _videoInfo = nil;

  // [bavv edit start]
  NSString *uriString = [source objectForKey:@"uri"];
  NSURL *uri = [NSURL URLWithString:uriString];
  int initType = [source objectForKey:@"initType"];
  NSDictionary *initOptions = [source objectForKey:@"initOptions"];

  if (initType == 1) {
    _player = [[VLCMediaPlayer alloc] init];
  } else {
    _player = [[VLCMediaPlayer alloc] initWithOptions:initOptions];
  }
  _player.delegate = self;
  _player.drawable = self;

  // [bavv edit end]

  _player.media = [VLCMedia mediaWithURL:uri];

  // 根据repeat属性设置循环播放
  if (_repeat) {
    [_player.media addOption:@"--input-repeat=1000"];
  } else {
    [_player.media addOption:@"--input-repeat=0"];
  }

  [[AVAudioSession sharedInstance]
        setActive:NO
      withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
            error:nil];

  // 初始化后应用当前的resizeMode
  [self setResizeMode:_resizeMode];
}

- (void)setAutoplay:(BOOL)autoplay {
  if (autoplay)
    [self play];
}

- (void)setPaused:(BOOL)paused {
  _paused = paused;

  if (!paused) {
    [self play];
  } else {
    [self pause];
  }
}

- (void)setResume:(BOOL)resume {
  if (resume) {
    [self play];
  } else {
    [self pause];
  }
}

- (void)setSubtitleUri:(NSString *)subtitleUri {
  NSURL *url = [NSURL URLWithString:subtitleUri];

  if (url.absoluteString.length != 0 && _player) {
    _subtitleUri = url;
    [_player addPlaybackSlave:_subtitleUri
                         type:VLCMediaPlaybackSlaveTypeSubtitle
                      enforce:YES];
  } else {
    NSLog(@"Invalid subtitle URI: %@", subtitleUri);
  }
}

// ==== player delegate methods ====

- (void)mediaPlayerTimeChanged:(NSNotification *)aNotification {
  [self updateVideoProgress];
}

- (void)mediaPlayerStateChanged:(NSNotification *)aNotification {

  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if (_player) {
    VLCMediaPlayerState state = _player.state;
    switch (state) {
    case VLCMediaPlayerStateOpening:
      self.onVideoOpen(@{@"target" : self.reactTag});
      self.onVideoLoadStart(@{@"target" : self.reactTag});
      break;
    case VLCMediaPlayerStatePaused:
      _paused = YES;
      self.onVideoPaused(@{@"target" : self.reactTag});
      break;
    case VLCMediaPlayerStateStopped:
      self.onVideoStopped(@{@"target" : self.reactTag});
      break;
    case VLCMediaPlayerStateBuffering:
      if (!_videoInfo && _player.numberOfAudioTracks > 0) {
        _videoInfo = [self getVideoInfo];
        self.onVideoLoad(_videoInfo);
      }
      self.onVideoBuffering(@{@"target" : self.reactTag});
      break;
    case VLCMediaPlayerStatePlaying:
      _paused = NO;
      self.onVideoPlaying(@{
        @"target" : self.reactTag,
        @"seekable" : [NSNumber numberWithBool:[_player isSeekable]],
        @"duration" : [NSNumber numberWithInt:[_player.media.length intValue]]
      });
      break;
    case VLCMediaPlayerStateError:
      self.onVideoError(@{@"target" : self.reactTag});
      [self _release];
      break;
    default:
      break;
    }
  }
}

//   ===== media delegate methods =====

- (void)mediaDidFinishParsing:(VLCMedia *)aMedia {
  NSLog(@"VLCMediaDidFinishParsing %i", _player.numberOfAudioTracks);
}

- (void)mediaMetaDataDidChange:(VLCMedia *)aMedia {
  NSLog(@"VLCMediaMetaDataDidChange %i", _player.numberOfAudioTracks);
}

//   ===================================

- (void)updateVideoProgress {
  if (_player && !_paused) {
    int currentTime = [[_player time] intValue];
    int remainingTime = [[_player remainingTime] intValue];
    int duration = [_player.media.length intValue];

    self.onVideoProgress(@{
      @"target" : self.reactTag,
      @"currentTime" : [NSNumber numberWithInt:currentTime],
      @"remainingTime" : [NSNumber numberWithInt:remainingTime],
      @"duration" : [NSNumber numberWithInt:duration],
      @"position" : [NSNumber numberWithFloat:_player.position]
    });
  }
}

- (NSDictionary *)getVideoInfo {
  NSMutableDictionary *info = [NSMutableDictionary new];
  info[@"duration"] = _player.media.length.value;
  int i;
  if (_player.videoSize.width > 0) {
    info[@"videoSize"] = @{
      @"width" : @(_player.videoSize.width),
      @"height" : @(_player.videoSize.height)
    };
  }

  if (_player.numberOfAudioTracks > 0) {
    NSMutableArray *tracks = [NSMutableArray new];
    for (i = 0; i < _player.numberOfAudioTracks; i++) {
      if (_player.audioTrackIndexes[i] && _player.audioTrackNames[i]) {
        [tracks addObject:@{
          @"id" : _player.audioTrackIndexes[i],
          @"name" : _player.audioTrackNames[i],
          @"isDefault" : [NSNumber
              numberWithBool:[_player.audioTrackIndexes[i] intValue] ==
                             _player.currentAudioTrackIndex]
        }];
      }
    }
    info[@"audioTracks"] = tracks;
  }

  if (_player.numberOfSubtitlesTracks > 0) {
    NSMutableArray *tracks = [NSMutableArray new];
    for (i = 0; i < _player.numberOfSubtitlesTracks; i++) {
      if (_player.videoSubTitlesIndexes[i] && _player.videoSubTitlesNames[i]) {
        [tracks addObject:@{
          @"id" : _player.videoSubTitlesIndexes[i],
          @"name" : _player.videoSubTitlesNames[i],
          @"isDefault" : [NSNumber
              numberWithBool:[_player.videoSubTitlesIndexes[i] intValue] ==
                             _player.currentVideoSubTitleIndex]
        }];
      }
    }
    info[@"textTracks"] = tracks;
  }

  return info;
}

- (void)jumpBackward:(int)interval {
  if (interval >= 0 && interval <= [_player.media.length intValue])
    [_player jumpBackward:interval];
}

- (void)jumpForward:(int)interval {
  if (interval >= 0 && interval <= [_player.media.length intValue])
    [_player jumpForward:interval];
}

- (void)setSeek:(float)pos {
  if ([_player isSeekable]) {
    if (pos >= 0 && pos <= 1) {
      [_player setPosition:pos];
    }
  }
}

- (void)setSeekTime:(int)timeInMS {
  if (_player && [_player isSeekable]) {
    NSLog(@"setSeekTime input (ms): %i", timeInMS);
    if (timeInMS >= 0 && timeInMS <= [_player.media.length intValue]) {
      // 将毫秒转换为微秒，因为VLC内部使用微秒
      long long timeInMicroSeconds = (long long)timeInMS * 1000;
      VLCTime *time = [VLCTime
          timeWithNumber:[NSNumber numberWithLongLong:timeInMicroSeconds]];
      NSLog(@"Setting time to microseconds: %lld", timeInMicroSeconds);
      [_player setTime:time];

      // 验证设置后的时间
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
            long long currentTimeMicros = [[_player.time value] longLongValue];
            NSLog(@"Current time after seek (ms): %lld",
                  currentTimeMicros / 1000);
          });
    }
  }
}

- (void)setSnapshotPath:(NSString *)path {
  if (_player)
    [_player saveVideoSnapshotAt:path withWidth:0 andHeight:0];
}

- (void)setRate:(float)rate {
  [_player setRate:rate];
}

- (void)setAudioTrack:(int)track {
  [_player setCurrentAudioTrackIndex:track];
}

- (void)setTextTrack:(int)track {
  [_player setCurrentVideoSubTitleIndex:track];
}

- (void)setVideoAspectRatio:(NSString *)ratio {
  char *char_content = [ratio cStringUsingEncoding:NSASCIIStringEncoding];
  [_player setVideoAspectRatio:char_content];
}

- (void)setRepeat:(BOOL)repeat {
  _repeat = repeat;

  if (_player && _player.media) {
    if (repeat) {
      // 设置VLC循环播放模式
      [_player.media addOption:@"--input-repeat=1000"];
    } else {
      // 设置为不重复模式
      [_player.media addOption:@"--input-repeat=0"];
    }
  }
}

- (void)setMuted:(BOOL)value {
  if (_player) {
    [[_player audio] setMuted:value];
  }
}

- (void)setResizeMode:(NSString *)resizeMode {
  _resizeMode = resizeMode; // 保存当前的模式

  if (!_player) {
    NSLog(@"RCTVLCPlayer: setResizeMode called but player is nil.");
    return;
  }
  NSLog(@"RCTVLCPlayer: Setting resizeMode to: %@", resizeMode);

  if ([resizeMode isEqualToString:@"cover"]) {
    CGRect viewBounds = self.bounds;
    float videoWidth = _player.videoSize.width;
    float videoHeight = _player.videoSize.height;

    if (viewBounds.size.width > 0 && viewBounds.size.height > 0 &&
        videoWidth > 0 && videoHeight > 0) {
      float viewWidth = viewBounds.size.width;
      float viewHeight = viewBounds.size.height;
      float viewAspect = viewWidth / viewHeight;
      float videoAspect = videoWidth / videoHeight;
      float scale = 1.0;

      if (viewAspect > videoAspect) {
        scale = viewWidth / videoWidth;
      } else {
        scale = viewHeight / videoHeight;
      }

      int cropWidth = viewWidth * scale;
      int cropHeight = viewHeight * scale;

      NSString *cropGeometry =
          [NSString stringWithFormat:@"%d:%d", cropWidth, cropHeight];
      NSLog(@"RCTVLCPlayer: Setting cover mode with cropGeometry: %@",
            cropGeometry);
      _player.videoCropGeometry = cropGeometry.UTF8String;
      [_player setVideoAspectRatio:NULL]; // Ensure aspect ratio is not set when
                                          // using crop
    } else {
      NSLog(@"RCTVLCPlayer: Cannot calculate crop for cover mode. Invalid view "
            @"bounds or video size.");
      // Fallback to contain behavior if dimensions are invalid
      _player.videoCropGeometry = NULL;
      [_player setVideoAspectRatio:NULL];
    }

  } else if ([resizeMode isEqualToString:@"contain"]) {
    // 对于 contain 模式，重置裁剪和宽高比，让 VLC 自行处理
    NSLog(@"RCTVLCPlayer: Setting contain mode");
    _player.videoCropGeometry = NULL;
    [_player setVideoAspectRatio:NULL];
  } else {
    // 默认情况同 contain
    NSLog(@"RCTVLCPlayer: Setting default mode (contain)");
    _player.videoCropGeometry = NULL;
    [_player setVideoAspectRatio:NULL];
  }
  [self setNeedsLayout];
  [self layoutIfNeeded];
}

// 重写layoutSubviews方法来处理旋转后的布局
- (void)layoutSubviews {
  [super layoutSubviews];
  // 当视图的 bounds 改变时（例如旋转完成或父视图调整），
  // 确保视频的 resizeMode 被重新应用以匹配新的尺寸。
  // 添加一个检查防止 _isUpdatingLayout 导致的潜在无限循环
  // (虽然不太可能在这里发生)
  if (!_isUpdatingLayout && _player && _resizeMode) {
    NSLog(@"RCTVLCPlayer: layoutSubviews triggered, re-applying resizeMode: %@",
          _resizeMode);
    // 标记开始更新布局，防止递归调用 setResizeMode -> layoutSubviews
    _isUpdatingLayout = YES;
    [self setResizeMode:_resizeMode];
    // 更新完成后重置标记
    _isUpdatingLayout = NO;
  }
}

- (void)_release {
  if (_player.media)
    [_player stop];

  if (_player)
    _player = nil;

  _eventDispatcher = nil;
}

#pragma mark - Lifecycle
- (void)removeFromSuperview {
  NSLog(@"RCTVLCPlayer: removeFromSuperview");
  // 移除所有通知观察者
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [self _release];
  [super removeFromSuperview];
}

// 处理方向变化的函数
- (void)orientationDidChange:(NSNotification *)notification {
  // 防止在布局更新过程中重复调用
  if (_isUpdatingLayout) {
    return;
  }

  UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];

  // 仅处理有效的横竖屏切换
  if (UIDeviceOrientationIsLandscape(orientation) ||
      UIDeviceOrientationIsPortrait(orientation)) {
    NSLog(@"RCTVLCPlayer: Orientation changed, applying resizeMode: %@",
          self->_resizeMode);
    // 标记我们正在处理方向变化，防止 layoutSubviews 触发的 setResizeMode 冲突
    _isUpdatingLayout = YES;
    // 直接调用 setResizeMode，此时 self.bounds 应该已经或即将更新
    // setResizeMode 内部会根据新的 bounds 设置正确的 aspect ratio (for cover)
    [self setResizeMode:self->_resizeMode];
    // 完成后重置标记
    _isUpdatingLayout = NO;
  }
  // 注意：对于 FaceUp/FaceDown 等情况，我们不执行任何操作，也不重置标记，
  // 因为 _isUpdatingLayout 在开始时就判断并返回了。
}

@end
