#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class VLCLibrary;
@class VLCMediaPlayer;
@class VlcTextureRenderer;

/// libVLC's events that VLCKit 3.7.4 drops or hides, read from the player's
/// raw libVLC pointer: the buffering percentage, a track deleted or selected,
/// each media's Opening and first time (which end a held picture), and
/// libVLC's log line for a refused seek. Callbacks come on libVLC's threads,
/// never call back into libVLC, and reach the plugin as one update per 100 ms
/// at most, on main.
@interface VlcPlayerEvents : NSObject

/// Reads libVLC's refused-seek warnings from [library]'s instance, for every
/// VlcPlayerEvents on it. libVLC keeps one log callback per instance and the
/// plugin's players share instances (one per set of options), so this is
/// installed once per library, by the plugin's library pool, and never
/// removed: the pool keeps its libraries for the process's life. Not for a
/// library given VLCKit's loggers (--verbose=2), which take that callback.
+ (void)readLogOfLibrary:(VLCLibrary *)library;

/// [renderer] is the texture target's, or nil for a view-backed player, which
/// cannot hold a picture. [readLog] counts the refused seeks that
/// +readLogOfLibrary: reads from [mediaPlayer]'s instance.
- (instancetype)initWithMediaPlayer:(VLCMediaPlayer *)mediaPlayer
                           renderer:(nullable VlcTextureRenderer *)renderer
                            readLog:(BOOL)readLog NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Called on main when a snapshot should be sent.
@property(nonatomic, copy, nullable) void (^onChanged)(void);

/// libVLC's prebuffer from 0 to 1, or a negative number when it isn't
/// prebuffering.
@property(nonatomic, readonly) double bufferingProgress;
/// Whether a keepPicture hold is on: VlcPictureHold's decision, which every
/// backend reports (FORK.md 30), not the renderer's pixels.
@property(nonatomic, readonly) BOOL pictureHeld;
@property(nonatomic, readonly) NSInteger seekRefusals;
/// The time libVLC last refused to seek to, in milliseconds; -1 when none.
@property(nonatomic, readonly) NSInteger seekRefusedAt;

/// Moves to [mediaPlayer], a fresh player for the next source on the same
/// library: the old player's events stop, and a hold armed or on carries
/// over. Main thread, before the new player is given media.
- (void)attachToMediaPlayer:(VLCMediaPlayer *)mediaPlayer;
/// A new media is about to be set: holds the picture on screen when asked to
/// and there is one.
- (void)armWithKeepPicture:(BOOL)keepPicture;
/// The host stopped the player: a hold ends.
- (void)stop;
/// Stops libVLC calling in. Idempotent; required before the player goes.
- (void)detach;

@end

NS_ASSUME_NONNULL_END
