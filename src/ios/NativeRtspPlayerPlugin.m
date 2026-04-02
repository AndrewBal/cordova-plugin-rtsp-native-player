#import "NativeRtspPlayerPlugin.h"
#import "RtspPlayerManager.h"

@interface NativeRtspPlayerPlugin () <RtspPlayerManagerDelegate>

@property (nonatomic, strong) RtspPlayerManager *manager;
@property (nonatomic, copy) NSString *callbackId;

@end

@implementation NativeRtspPlayerPlugin

- (void)pluginInitialize {
    NSLog(@"[NativeRtspPlugin] Initialized");
}

// ─────────────────────────────────────────────
#pragma mark - Cordova Actions
// ─────────────────────────────────────────────

- (void)play:(CDVInvokedUrlCommand *)command {
    NSString *frontUrl   = [command argumentAtIndex:0 withDefault:@""];
    NSString *rearUrl    = [command argumentAtIndex:1 withDefault:@""];
    NSString *title      = [command argumentAtIndex:2 withDefault:@"Live"];
    NSString *apiBaseUrl = [command argumentAtIndex:3 withDefault:@""];
    
    if (frontUrl.length == 0) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                    messageAsString:@"frontUrl is required"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }
    
    // Store callback for streaming status updates (keepCallback = YES)
    _callbackId = command.callbackId;
    
    NSLog(@"[NativeRtspPlugin] play: front=%@ rear=%@ title=%@ api=%@", frontUrl, rearUrl, title, apiBaseUrl);
    
    // Stop any existing session
    if (_manager) {
        [_manager stop];
    }
    
    _manager = [RtspPlayerManager new];
    _manager.delegate = self;
    
    [_manager playWithFrontUrl:frontUrl
                       rearUrl:rearUrl.length > 0 ? rearUrl : nil
                         title:title
                    apiBaseUrl:apiBaseUrl.length > 0 ? apiBaseUrl : nil
                     presenter:self.viewController];
}

- (void)stop:(CDVInvokedUrlCommand *)command {
    if (_manager) {
        [_manager stop];
        _manager = nil;
    }
    
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

// ─────────────────────────────────────────────
#pragma mark - RtspPlayerManagerDelegate
// ─────────────────────────────────────────────

- (void)playerManager:(id)manager didChangeStatus:(NSString *)status message:(NSString *)message {
    if (!_callbackId) return;
    
    NSDictionary *payload = @{
        @"type": @"status",
        @"value": status,
        @"message": message ?: [NSNull null]
    };
    
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                           messageAsDictionary:payload];
    [result setKeepCallbackAsBool:YES];  // Keep channel open for future updates
    [self.commandDelegate sendPluginResult:result callbackId:_callbackId];
    
    // If CLOSED, release the callback
    if ([status isEqualToString:@"CLOSED"]) {
        CDVPluginResult *finalResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                    messageAsDictionary:payload];
        [finalResult setKeepCallbackAsBool:NO];
        [self.commandDelegate sendPluginResult:finalResult callbackId:_callbackId];
        _callbackId = nil;
    }
}

- (void)playerManager:(id)manager didFailWithError:(NSString *)error {
    if (!_callbackId) return;
    
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                messageAsString:error];
    [result setKeepCallbackAsBool:NO];
    [self.commandDelegate sendPluginResult:result callbackId:_callbackId];
    _callbackId = nil;
}

- (void)playerManager:(id)manager didReceiveAction:(NSString *)action camera:(NSString *)camera data:(NSDictionary *)data {
    if (!_callbackId) return;
    
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"type"] = @"action";
    payload[@"value"] = action;
    if (camera) payload[@"camera"] = camera;
    if (data) payload[@"data"] = data;
    
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                           messageAsDictionary:payload];
    [result setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:result callbackId:_callbackId];
}

@end
