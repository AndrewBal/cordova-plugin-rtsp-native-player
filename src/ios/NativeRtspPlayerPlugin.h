#import <Cordova/CDVPlugin.h>

@interface NativeRtspPlayerPlugin : CDVPlugin

- (void)play:(CDVInvokedUrlCommand *)command;
- (void)stop:(CDVInvokedUrlCommand *)command;

@end
