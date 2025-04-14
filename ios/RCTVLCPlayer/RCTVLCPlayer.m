#import "RCTVLCPlayer.h"
#import "React/RCTBridgeModule.h"
#import "React/RCTConvert.h"
#import "React/RCTEventDispatcher.h"
#import "React/UIView+React.h"
#if TARGET_OS_TV
#import <TVVLCKit/TVVLCKit.h>
#else
#import <MobileVLCKit/MobileVLCKit.h>
#endif
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIDevice.h>
#import <UIKit/UIKit.h>
#import <UIKit/UIWindowScene.h>

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
  NSLog(@"userInfo %@", [aNotification userInfo]);
  NSLog(@"standardUserDefaults %@", defaults);
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
  if (!_player) {
    return;
  }

  _resizeMode = resizeMode;

  if ([resizeMode isEqualToString:@"cover"]) {
    UIScreen *screen = [UIScreen mainScreen];
    CGRect screenBounds = screen.bounds;

    // 根据当前frame的宽高比确定方向，而不是依赖_isLandscape变量
    float screenWidth, screenHeight;
    BOOL isFrameLandscape = self.frame.size.width > self.frame.size.height;

    if (isFrameLandscape) {
      screenWidth = MAX(screenBounds.size.width, screenBounds.size.height);
      screenHeight = MIN(screenBounds.size.width, screenBounds.size.height);
    } else {
      screenWidth = MIN(screenBounds.size.width, screenBounds.size.height);
      screenHeight = MAX(screenBounds.size.width, screenBounds.size.height);
    }

    // 使用当前frame的尺寸而不是屏幕尺寸
    screenWidth = self.frame.size.width;
    screenHeight = self.frame.size.height;

    float f_ar = screenWidth / screenHeight;

    NSString *cropGeometry =
        [NSString stringWithFormat:@"%.0f:%.0f", screenWidth, screenHeight];
    _player.videoCropGeometry = cropGeometry.UTF8String;
    [_player setVideoAspectRatio:NULL];
  } else if ([resizeMode isEqualToString:@"contain"]) {
    NSLog(@"设置contain模式");
    [_player setVideoAspectRatio:NULL];
    _player.videoCropGeometry = NULL;
  } else {
    NSLog(@"设置默认模式");
    [_player setVideoAspectRatio:NULL];
    _player.videoCropGeometry = NULL;
  }

  [self setNeedsLayout];
  [self layoutIfNeeded];
}

// 重写layoutSubviews方法来处理旋转后的布局
- (void)layoutSubviews {
  [super layoutSubviews];
}

- (void)_release {
  [[NSNotificationCenter defaultCenter] removeObserver:self];

  // 停止设备方向监听
  [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];

  if (_player.media)
    [_player stop];

  if (_player)
    _player = nil;

  _eventDispatcher = nil;
}

#pragma mark - Lifecycle
- (void)removeFromSuperview {
  NSLog(@"removeFromSuperview");
  [self _release];
  [super removeFromSuperview];
}

@end
