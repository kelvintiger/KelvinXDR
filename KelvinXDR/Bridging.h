//
//  Bridging.h
//  KelvinXDR
//
//  Private symbols. Apple ships no public API for external-display brightness or for the
//  system OSD, so these are the same undocumented entry points MonitorControl, Lunar and
//  BetterDisplay all rely on.
//

#pragma once

#import <Foundation/Foundation.h>
#import <IOKit/i2c/IOI2CInterface.h>
#import <CoreGraphics/CoreGraphics.h>

// MARK: - DDC/CI over I2C (IOKit, Apple Silicon)

typedef CFTypeRef IOAVService;

extern IOAVService IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVService service, uint32_t chipAddress, uint32_t offset, void *outputBuffer, uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVService service, uint32_t chipAddress, uint32_t dataAddress, void *inputBuffer, uint32_t inputBufferSize);

// MARK: - Native Apple brightness
//
// DisplayServices is a private framework with no SDK stub, so it cannot be linked.
// AppleBrightness.swift resolves these with dlopen/dlsym at runtime instead.

// MARK: - System OSD (OSDUIHelper XPC)

@class NSString;

@protocol OSDUIHelperProtocol
- (void)showImageAtPath:(NSString *)arg1 onDisplayID:(unsigned int)arg2 priority:(unsigned int)arg3 msecUntilFade:(unsigned int)arg4 withText:(NSString *)arg5;
- (void)showImage:(long long)arg1 onDisplayID:(unsigned int)arg2 priority:(unsigned int)arg3 msecUntilFade:(unsigned int)arg4 filledChiclets:(unsigned int)arg5 totalChiclets:(unsigned int)arg6 locked:(BOOL)arg7;
- (void)showImage:(long long)arg1 onDisplayID:(unsigned int)arg2 priority:(unsigned int)arg3 msecUntilFade:(unsigned int)arg4;
@end
