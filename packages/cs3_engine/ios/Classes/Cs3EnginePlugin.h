#import <Flutter/Flutter.h>

/// Hosts the CS3 engine in an embedded OpenJDK Zero VM (no JIT) and answers the
/// `cs3_engine` method channel.
@interface Cs3EnginePlugin : NSObject <FlutterPlugin>
@end
