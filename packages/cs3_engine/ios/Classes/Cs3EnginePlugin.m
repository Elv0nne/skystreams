#import "Cs3EnginePlugin.h"

#import <OpenJDKRuntime/jni.h>

// The Zero interpreter keeps Java frames on the native stack, and iOS gives GCD
// workers only 512 KB, so every JNI call runs on one of these 8 MB threads. Requests only
// pass through them (the engine answers later, see Reply), so a few are enough.
static const NSUInteger kJvmStackSize = 8 * 1024 * 1024;
static const NSUInteger kWorkerCount = 2;

static JavaVM *gVM;
static jclass gEntry;
static jmethodID gStart;
static jmethodID gSubmit;
static FlutterMethodChannel *gChannel;

// Requests the engine has not answered yet, by token.
static NSMutableDictionary<NSNumber *, void (^)(NSString *)> *gPending;
static int64_t gNextToken;

#pragma mark - JNI helpers

// UTF-16 in and out: JNI's "UTF" calls use modified UTF-8, which mangles emoji.
static jstring JStringFrom(JNIEnv *env, NSString *string) {
  NSUInteger length = string.length;
  unichar *buffer = malloc(MAX(length, 1) * sizeof(unichar));
  [string getCharacters:buffer range:NSMakeRange(0, length)];
  jstring result = (*env)->NewString(env, buffer, (jsize)length);
  free(buffer);
  return result;
}

static NSString *NSStringFrom(JNIEnv *env, jstring string) {
  if (string == NULL) return nil;
  const jchar *chars = (*env)->GetStringChars(env, string, NULL);
  NSString *result = [NSString stringWithCharacters:chars length:(NSUInteger)(*env)->GetStringLength(env, string)];
  (*env)->ReleaseStringChars(env, string, chars);
  return result;
}

static NSString *PendingExceptionMessage(JNIEnv *env) {
  jthrowable thrown = (*env)->ExceptionOccurred(env);
  if (thrown == NULL) return nil;
  (*env)->ExceptionClear(env);
  jclass throwable = (*env)->FindClass(env, "java/lang/Throwable");
  jmethodID toString = (*env)->GetMethodID(env, throwable, "toString", "()Ljava/lang/String;");
  jstring text = (jstring)(*env)->CallObjectMethod(env, thrown, toString);
  NSString *message = NSStringFrom(env, text) ?: @"unknown Java exception";
  (*env)->ExceptionClear(env);
  // Worker threads stay attached for the life of the app, so their local references add up.
  if (text) (*env)->DeleteLocalRef(env, text);
  (*env)->DeleteLocalRef(env, throwable);
  (*env)->DeleteLocalRef(env, thrown);
  return message;
}

static NSString *ErrorResponse(NSString *type, NSString *message) {
  NSDictionary *body = @{@"id" : [NSNull null], @"error" : @{@"type" : type, @"message" : message ?: @""}};
  NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

#pragma mark - Events

/// EmbeddedEntry.emit: an event from the engine, on one of its own threads; Dart hears it on the channel.
static void JNICALL Emit(JNIEnv *env, jclass entry, jstring event) {
  NSString *message = NSStringFrom(env, event);
  if (message == nil) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    [gChannel invokeMethod:@"event" arguments:message];
  });
}

/// EmbeddedEntry.reply: the engine's answer to a submitted request, on one of its own threads.
static void JNICALL Reply(JNIEnv *env, jclass entry, jlong token, jstring response) {
  NSString *message = NSStringFrom(env, response);
  void (^completion)(NSString *) = nil;
  @synchronized(gPending) {
    completion = gPending[@(token)];
    [gPending removeObjectForKey:@(token)];
  }
  if (completion != nil) completion(message ?: ErrorResponse(@"JavaException", @"empty response"));
}

#pragma mark - VM start-up

static NSArray<NSString *> *EngineJars(NSString *engineDir) {
  NSMutableArray<NSString *> *jars = [NSMutableArray array];
  for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:engineDir error:nil]) {
    if ([name hasSuffix:@".jar"]) [jars addObject:[engineDir stringByAppendingPathComponent:name]];
  }
  return [jars sortedArrayUsingSelector:@selector(compare:)];
}

/// Creates the VM on the calling (big-stack) thread and starts the engine. Returns an error message or nil.
static NSString *StartVM(NSString *engineDir, NSString *dataDir) {
  // The VM derives java.home as <OpenJDKRuntime.framework>/lib; the extra modules live beside it.
  NSString *framework = [[NSBundle mainBundle].privateFrameworksPath stringByAppendingPathComponent:@"OpenJDKRuntime.framework"];
  NSArray<NSString *> *jars = EngineJars(engineDir);
  if (jars.count == 0) return [NSString stringWithFormat:@"no engine jars in %@", engineDir];

  NSArray<NSString *> *optionStrings = @[
    [@"-Djava.class.path=" stringByAppendingString:[jars componentsJoinedByString:@":"]],
    [NSString stringWithFormat:@"-Xbootclasspath/a:%@/lib/extras/java.logging.jar:%@/lib/extras/jdk.unsupported.jar",
                               framework, framework],
    // java.logging and jdk.unsupported run from the boot class path, outside their modules.
    @"--add-exports=java.base/jdk.internal.access=ALL-UNNAMED",
    @"--add-exports=java.base/jdk.internal.misc=ALL-UNNAMED",
    @"--add-exports=java.base/jdk.internal.loader=ALL-UNNAMED",
    @"--add-exports=java.base/jdk.internal.logger=ALL-UNNAMED",
    @"--add-exports=java.base/jdk.internal.reflect=ALL-UNNAMED",
    @"--add-exports=java.base/sun.util.logging=ALL-UNNAMED",
    [@"-Djava.io.tmpdir=" stringByAppendingString:NSTemporaryDirectory()],
    [@"-Duser.home=" stringByAppendingString:dataDir],
    @"-Dfile.encoding=UTF-8",
    @"-Djava.awt.headless=true",
    @"-XX:+UseSerialGC",
    @"-Xss8m",
    @"-Xms64m",
    @"-Xmx512m",
  ];
  JavaVMOption *options = calloc(optionStrings.count, sizeof(JavaVMOption));
  for (NSUInteger i = 0; i < optionStrings.count; i++) {
    options[i].optionString = strdup(optionStrings[i].UTF8String);
  }
  JavaVMInitArgs args = {JNI_VERSION_1_8, (jint)optionStrings.count, options, JNI_FALSE};
  JNIEnv *env = NULL;
  jint created = JNI_CreateJavaVM(&gVM, (void **)&env, &args);
  for (NSUInteger i = 0; i < optionStrings.count; i++) free(options[i].optionString);
  free(options);
  if (created != JNI_OK) return [NSString stringWithFormat:@"JNI_CreateJavaVM failed (%d)", created];

  jclass entry = (*env)->FindClass(env, "dev/akash/cs3engine/jvm/EmbeddedEntry");
  if (entry == NULL) return PendingExceptionMessage(env) ?: @"EmbeddedEntry not found";
  gEntry = (*env)->NewGlobalRef(env, entry);
  gStart = (*env)->GetStaticMethodID(env, gEntry, "start", "(Ljava/lang/String;Ljava/lang/String;)V");
  gSubmit = (*env)->GetStaticMethodID(env, gEntry, "submit", "(JLjava/lang/String;)V");
  JNINativeMethod natives[] = {
      {(char *)"emit", (char *)"(Ljava/lang/String;)V", (void *)Emit},
      {(char *)"reply", (char *)"(JLjava/lang/String;)V", (void *)Reply},
  };
  if ((*env)->RegisterNatives(env, gEntry, natives, 2) != JNI_OK) {
    return PendingExceptionMessage(env) ?: @"EmbeddedEntry's native methods could not be registered";
  }
  (*env)->CallStaticVoidMethod(env, gEntry, gStart, JStringFrom(env, dataDir), JStringFrom(env, @"ios"));
  return PendingExceptionMessage(env);
}

#pragma mark - Worker threads

@interface Cs3JvmWorkers : NSObject
- (instancetype)initWithEngineDir:(NSString *)engineDir;
- (void)submitRequest:(NSString *)request dataDir:(NSString *)dataDir completion:(void (^)(NSString *))completion;
@end

@implementation Cs3JvmWorkers {
  NSString *_engineDir;
  NSCondition *_condition;
  NSMutableArray<dispatch_block_t> *_queue;
  NSString *_startError;
  BOOL _started;
}

- (instancetype)initWithEngineDir:(NSString *)engineDir {
  if ((self = [super init])) {
    gPending = [NSMutableDictionary dictionary];
    _engineDir = engineDir;
    _condition = [[NSCondition alloc] init];
    _queue = [NSMutableArray array];
    for (NSUInteger i = 0; i < kWorkerCount; i++) {
      NSThread *thread = [[NSThread alloc] initWithTarget:self selector:@selector(runWorker) object:nil];
      thread.stackSize = kJvmStackSize;
      thread.name = [NSString stringWithFormat:@"cs3-jvm-%lu", (unsigned long)i];
      [thread start];
    }
  }
  return self;
}

- (void)runWorker {
  while (YES) {
    [_condition lock];
    while (_queue.count == 0) [_condition wait];
    dispatch_block_t job = _queue.firstObject;
    [_queue removeObjectAtIndex:0];
    [_condition unlock];
    job();
  }
}

- (void)submitRequest:(NSString *)request dataDir:(NSString *)dataDir completion:(void (^)(NSString *))completion {
  __weak Cs3JvmWorkers *weakSelf = self;
  [_condition lock];
  [_queue addObject:^{
    Cs3JvmWorkers *strongSelf = weakSelf;
    NSString *error = [strongSelf ensureStartedWithDataDir:dataDir];
    if (error != nil) {
      completion(ErrorResponse(@"EngineStartError", error));
      return;
    }
    // Workers stay attached once they have run a job; the creating thread already is.
    JNIEnv *jni = NULL;
    if ((*gVM)->GetEnv(gVM, (void **)&jni, JNI_VERSION_1_8) != JNI_OK) {
      (*gVM)->AttachCurrentThread(gVM, (void **)&jni, NULL);
    }
    int64_t token;
    @synchronized(gPending) {
      token = ++gNextToken;
      gPending[@(token)] = completion;
    }
    jstring jRequest = JStringFrom(jni, request);
    (*jni)->CallStaticVoidMethod(jni, gEntry, gSubmit, (jlong)token, jRequest);
    (*jni)->DeleteLocalRef(jni, jRequest);
    NSString *exception = PendingExceptionMessage(jni);
    if (exception != nil) {
      @synchronized(gPending) {
        [gPending removeObjectForKey:@(token)];
      }
      completion(ErrorResponse(@"JavaException", exception));
    }
  }];
  [_condition signal];
  [_condition unlock];
}

/// The first job to arrive creates the VM on its own (big-stack) worker thread.
- (NSString *)ensureStartedWithDataDir:(NSString *)dataDir {
  @synchronized(self) {
    if (!_started) {
      [[NSFileManager defaultManager] createDirectoryAtPath:dataDir withIntermediateDirectories:YES attributes:nil error:nil];
      _startError = StartVM(_engineDir, dataDir);
      _started = YES;
    }
    return _startError;
  }
}
@end

#pragma mark - Plugin

@implementation Cs3EnginePlugin {
  NSString *_engineDir;
  Cs3JvmWorkers *_workers;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel = [FlutterMethodChannel methodChannelWithName:@"cs3_engine"
                                                              binaryMessenger:[registrar messenger]];
  gChannel = channel;
  Cs3EnginePlugin *instance = [[Cs3EnginePlugin alloc] init];
  // Engine jars are this package's Flutter assets.
  NSString *key = [registrar lookupKeyForAsset:@"assets/engine" fromPackage:@"cs3_engine"];
  instance->_engineDir = [[NSBundle mainBundle] pathForResource:key ofType:nil];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if (![call.method isEqualToString:@"call"]) {
    result(FlutterMethodNotImplemented);
    return;
  }
  // Threads, and then the VM, only once the app uses the engine: registration starts nothing.
  if (_workers == nil) _workers = [[Cs3JvmWorkers alloc] initWithEngineDir:_engineDir];
  [_workers submitRequest:call.arguments[@"request"]
                  dataDir:call.arguments[@"dataDir"]
               completion:^(NSString *response) {
                 dispatch_async(dispatch_get_main_queue(), ^{
                   result(response);
                 });
               }];
}

@end
