#import "RCTVLCPlayer.h"
#import "RCTVLCPlayerViewController.h"
#import "React/RCTBridgeModule.h"
#import "React/RCTConvert.h"
#import "React/RCTEventDispatcher.h"
#import "React/UIView+React.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIDevice.h>
#import <UIKit/UIKit.h>
#import <UIKit/UIWindowScene.h>
#import <VLCKit/VLCKit.h>
#import <React/RCTUtils.h>

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
  BOOL _isUpdatingLayout;

  int _startTime;

  NSString *_resizeMode;
  UIView *_originalParentView;
  CGRect _originalFrame;

  // 视频控制器
  RCTVLCPlayerViewController *_playerViewController;
}

- (instancetype)initWithEventDispatcher:(RCTEventDispatcher *)eventDispatcher {
  if ((self = [super init])) {
    NSLog(@"[VLCPlayer][Init] 初始化播放器视图");
    _eventDispatcher = eventDispatcher;

    // 初始化视频控制器
    _playerViewController = [[RCTVLCPlayerViewController alloc] init];
      
    // 获取最近的 React Native 父 ViewController
    UIResponder *responder = self;
    while (responder && ![responder isKindOfClass:[UIViewController class]]) {
      responder = [responder nextResponder];
    }
    UIViewController *parentVC = (UIViewController *)responder;
    if (parentVC) {
      NSLog(@"[VLCPlayer][Init] 找到 parentVC: %@", parentVC);
      [parentVC addChildViewController:_playerViewController];
      [_playerViewController didMoveToParentViewController:parentVC];
    }

    [self addSubview:_playerViewController.view];
    _playerViewController.view.frame = self.bounds;
    _playerViewController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
      

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
  NSLog(@"[VLCPlayer][Source] 开始设置媒体源: %@", source);

  if (_player) {
    NSLog(@"[VLCPlayer][Source] 当前播放器状态: %d", (int)_player.state);
    [self _release];
  }

  // 检查source参数
  if (!source || ![source isKindOfClass:[NSDictionary class]]) {
    return;
  }

  // 获取并验证URI
  NSString *uriString = [source objectForKey:@"uri"];
  if (!uriString || ![uriString isKindOfClass:[NSString class]]) {
    return;
  }

  NSURL *uri = [NSURL URLWithString:uriString];
  if (!uri) {
    return;
  }

  // 获取初始化类型，默认为0
  NSNumber *initTypeNum = [source objectForKey:@"initType"];
  int initType =
      [initTypeNum isKindOfClass:[NSNumber class]] ? [initTypeNum intValue] : 0;

  // 获取初始化选项
  NSArray *initOptions = [source objectForKey:@"initOptions"];

  // 创建新的播放器实例
  @try {
    NSLog(@"[VLCPlayer][Source] 创建播放器实例 type=%d", initType);
    if (initType == 1) {
      _player = [[VLCMediaPlayer alloc] init];
    } else {
      _player = [[VLCMediaPlayer alloc] initWithOptions:initOptions];
    }

    if (!_player) {
      NSLog(@"[VLCPlayer][Error] 播放器创建失败");
      return;
    }

    NSLog(@"[VLCPlayer][Source] 播放器创建成功，设置代理");
    _player.delegate = self;

    // 更新播放器控制器中的播放器引用
    _playerViewController.player = _player;

    // 设置视频输出视图
    _player.drawable = _playerViewController.videoView;

    _player.media = [VLCMedia mediaWithURL:uri];

    // 设置循环播放
    if (_repeat) {
      [_player.media addOption:@"input-repeat=1000"];
    } else {
      [_player.media addOption:@"input-repeat=0"];
    }

    // 设置音频会话
    [[AVAudioSession sharedInstance]
          setActive:NO
        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
              error:nil];

    // 触发播放（如果需要）
    if (!_paused) {
      [_player play];
    }
  } @catch (NSException *exception) {
    NSLog(@"[VLCPlayer][Error] 初始化异常: %@\nreason: %@\ncallStack: %@",
          exception.name, exception.reason, exception.callStackSymbols);
    [self _release];
    return;
  }
}

- (void)setAutoplay:(BOOL)autoplay {
  if (autoplay) {
    [self play];
    [self setResizeMode:_resizeMode];
  }
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
    // NSLog(@"Invalid subtitle URI: %@", subtitleUri); // Removed
  }
}

// ==== player delegate methods ====

- (void)mediaPlayerTimeChanged:(NSNotification *)aNotification {
  [self updateVideoProgress];
}

- (void)mediaPlayerStateChanged:(VLCMediaPlayerState)currentState {

  if (!self || !_player) {
    return;
  }

  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf || !strongSelf->_player) {
      return;
    }

    @try {
      VLCMediaPlayerState state = currentState;
      switch (state) {
      case VLCMediaPlayerStateOpening:
        if (strongSelf.onVideoOpen) {
          strongSelf.onVideoOpen(@{@"target" : @(1)});
        }
        if (strongSelf.onVideoLoadStart) {
          strongSelf.onVideoLoadStart(@{@"target" : @(1)});
        }
        break;

      case VLCMediaPlayerStatePaused:
        strongSelf->_paused = YES;
        if (strongSelf.onVideoPaused) {
          strongSelf.onVideoPaused(@{@"target" : @(1)});
        }
        break;

      case VLCMediaPlayerStateStopped:
        if (strongSelf.onVideoStopped) {
          strongSelf.onVideoStopped(@{@"target" : @(1)});
        }
        break;

      case VLCMediaPlayerStateBuffering:
        if (!strongSelf->_videoInfo) {
          // 获取音频轨道
          NSArray *audioTracks = [strongSelf->_player audioTracks];
          if (audioTracks && audioTracks.count > 0) {
            strongSelf->_videoInfo = [strongSelf getVideoInfo];

            // 设置起始时间
            if (strongSelf->_startTime > 0) {
              [strongSelf setStartTime:strongSelf->_startTime];
            }

            if (strongSelf.onVideoLoad && strongSelf->_videoInfo) {
              strongSelf.onVideoLoad(strongSelf->_videoInfo);
            }
          }
        }

        if (strongSelf.onVideoBuffering) {
          strongSelf.onVideoBuffering(@{@"target" : @(1)});
        }
        break;

      case VLCMediaPlayerStatePlaying:
        NSLog(@"[VLCPlayer] 状态: 正在播放");
        strongSelf->_paused = NO;
        if (strongSelf.onVideoPlaying && strongSelf->_player.media) {
          strongSelf.onVideoPlaying(@{
            @"target" : @(1),
            @"seekable" : @(strongSelf->_player.isSeekable),
            @"duration" : @(strongSelf->_player.media.length.intValue)
          });
        }
        break;

      case VLCMediaPlayerStateStopping:
        NSLog(@"[VLCPlayer] 状态: 正在停止");
        break;

      case VLCMediaPlayerStateError:
        NSLog(@"[VLCPlayer] 状态: 播放错误");
        if (strongSelf.onVideoError) {
          strongSelf.onVideoError(@{@"target" : @(1)});
        }
        [strongSelf _release];
        break;

      default:
        break;
      }
    } @catch (NSException *exception) {
      NSLog(@"[VLCPlayer][Error] 状态处理异常: %@\nreason: %@\ncallStack: %@",
            exception.name, exception.reason, exception.callStackSymbols);
      if (strongSelf->_player) {
        [strongSelf _release];
      }
    }
  });
}

//   ===== media delegate methods =====

- (void)mediaDidFinishParsing:(VLCMedia *)aMedia {
}

- (void)mediaMetaDataDidChange:(VLCMedia *)aMedia {
}

//   ===================================

- (void)updateVideoProgress {
  if (_player && !_paused) {
    int currentTime = [[_player time] intValue];
    int remainingTime = [[_player remainingTime] intValue];
    int duration = [_player.media.length intValue];

    // 检查 startTime 是否设置成功
    BOOL startTimeSetSuccessfully = NO;
    if (_startTime > 0 && currentTime >= _startTime) {
      startTimeSetSuccessfully = YES;
    }

    self.onVideoProgress(@{
      @"target" : self.reactTag,
      @"currentTime" : [NSNumber numberWithInt:currentTime],
      @"remainingTime" : [NSNumber numberWithInt:remainingTime],
      @"duration" : [NSNumber numberWithInt:duration],
      @"position" : [NSNumber numberWithFloat:_player.position],
      @"startTimeSetSuccessfully" : @(startTimeSetSuccessfully) // 添加新的字段
    });
  }
}

- (NSDictionary *)getVideoInfo {
  NSMutableDictionary *info = [NSMutableDictionary new];
  info[@"duration"] = _player.media.length.value;

  if (_player.videoSize.width > 0) {
    info[@"videoSize"] = @{
      @"width" : @(_player.videoSize.width),
      @"height" : @(_player.videoSize.height)
    };
  }

  // 获取音频轨道
  NSArray *audioTracks = [_player audioTracks];
  if (audioTracks && audioTracks.count > 0) {
    NSMutableArray *tracks = [NSMutableArray new];
    for (NSUInteger i = 0; i < audioTracks.count; i++) {
      VLCMediaPlayerTrack *track = audioTracks[i];
      if (track) {
        [tracks addObject:@{
          @"id" : @(i),
          @"name" : track.trackName,
          @"isDefault" : @(track.isSelectedExclusively)
        }];
      }
    }
    if (tracks.count > 0) {
      info[@"audioTracks"] = tracks;
    }
  }

  // 获取字幕轨道
  NSArray *subtitleTracks = [_player textTracks];

  if (subtitleTracks && subtitleTracks.count > 0) {
    NSMutableArray *tracks = [NSMutableArray new];
    for (NSUInteger i = 0; i < subtitleTracks.count; i++) {
      VLCMediaPlayerTrack *track = subtitleTracks[i];
      if (track) {
        [tracks addObject:@{
          @"id" : @(i),
          @"name" : track.trackName,
          @"isDefault" : @(track.isSelectedExclusively)
        }];
      }
    }
    if (tracks.count > 0) {
      info[@"textTracks"] = tracks;
    }
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
    if (timeInMS >= 0 && timeInMS <= [_player.media.length intValue]) {
      long long timeInMicroSeconds = (long long)timeInMS * 1000;
      VLCTime *time = [VLCTime
          timeWithNumber:[NSNumber numberWithLongLong:timeInMicroSeconds]];
      [_player setTime:time];

      // 验证设置后的时间
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
            long long currentTimeMicros = [[_player.time value] longLongValue];
          });
    }
  }
}

- (void)setStartTime:(int)startTime {
  _startTime = startTime;
  if (_player && _player.media) {
    if (startTime > 0 && [_player isSeekable]) {
      long long timeInMicroSeconds = (long long)startTime * 1000;
      VLCTime *time = [VLCTime
          timeWithNumber:[NSNumber numberWithLongLong:timeInMicroSeconds]];
      [_player setTime:time];
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
  NSUInteger trackIndex = track; // 假设 track 是传入的索引值
  if (_player) {
    NSArray *audioTracks = [_player audioTracks];
    NSUInteger count = audioTracks.count;
    if (trackIndex >= 0 && trackIndex < count) {
      VLCMediaPlayerTrack *track = audioTracks[trackIndex];
      track.selectedExclusively = YES;
    }
  }
}

- (void)setTextTrack:(int)track {
  NSUInteger trackIndex = track; // 假设 track 是传入的索引值

  if (_player) {
    NSArray *textTracks = [_player textTracks];
    NSUInteger count = textTracks.count;

    if (trackIndex >= 0 && trackIndex < count) {
      VLCMediaPlayerTrack *track = textTracks[trackIndex];
      track.selectedExclusively = YES;
    } else {
      NSLog(@"Invalid text track index: %d", track);
    }
  }
}

- (void)setVideoAspectRatio:(NSString *)ratio {
  if (ratio && ratio.length > 0) {
    [_player setVideoAspectRatio:ratio];
  }
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
  _resizeMode = resizeMode;
  [_playerViewController setResizeMode:resizeMode];
}

// 重写layoutSubviews方法来处理旋转后的布局
- (void)layoutSubviews {
  [super layoutSubviews];
  // 更新播放器控制器视图的大小
  // _playerViewController.view.frame = self.bounds;
}

- (void)_release {
  @try {
    if (_player) {
      // 停止播放
      [_player pause];

      // 清除 delegate 和 drawable
      _player.delegate = nil;
      _player.drawable = nil;

      // 更新控制器中的播放器引用
      _playerViewController.player = nil;

      // 短暂延迟，确保 VLCKit 内部线程完成任务
      [NSThread sleepForTimeInterval:0.1];

      // 释放播放器
      _player = nil;
    }
    _videoInfo = nil;
    _paused = YES;
  } @catch (NSException *exception) {
    NSLog(@"[VLCPlayer][Error] 释放异常: %@\nreason: %@\ncallStack: %@",
          exception.name, exception.reason, exception.callStackSymbols);
  }
}

#pragma mark - Lifecycle
- (void)removeFromSuperview {
  // 先移除所有通知观察者，防止后续回调
  [[NSNotificationCenter defaultCenter] removeObserver:self];

  // 确保在主线程释放资源
  dispatch_async(dispatch_get_main_queue(), ^{
    // 使用锁保护资源释放
    @synchronized(self) {
      [self _release];
    }
    NSLog(@"[VLCPlayer] removeFromSuperview 资源释放完成");
  });

  [super removeFromSuperview];
  NSLog(@"[VLCPlayer] removeFromSuperview 完成");
}

// 实现videoOutputView的getter，返回ViewController中的videoView
- (UIView *)videoOutputView {
  return _playerViewController.videoView;
}

@end
