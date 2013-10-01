//
//  FFUtilities.m
//  LiveStreamer
//
//  Created by Christopher Ballinger on 10/1/13.
//  Copyright (c) 2013 OpenWatch, Inc. All rights reserved.
//

#import "FFUtilities.h"
#import "libavutil/error.h"

static NSString * const kFFmpegErrorDomain = @"org.ffmpeg.FFmpeg";
static NSString * const kFFmpegErrorCode = @"kFFmpegErrorCode";

@implementation FFUtilities

+ (NSError*) errorForAVError:(int)errorNumber {
    NSString *errorString = [self stringForAVErrorNumber:errorNumber];
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithCapacity:1];
    if (errorString) {
        [userInfo setObject:errorString forKey:NSLocalizedDescriptionKey];
    } else {
        [userInfo setObject:@"Unknown FFmpeg Error" forKey:NSLocalizedDescriptionKey];
    }
    [userInfo setObject:@(errorNumber) forKey:kFFmpegErrorCode];
    return [NSError errorWithDomain:kFFmpegErrorDomain code:errorNumber userInfo:userInfo];
}

+ (NSString*) stringForAVErrorNumber:(int)errorNumber {
    NSString *errorString = nil;
    char *errorBuffer = malloc(sizeof(char) * AV_ERROR_MAX_STRING_SIZE);
    
    int value = av_strerror(errorNumber, errorBuffer, AV_ERROR_MAX_STRING_SIZE);
    if (value != 0) {
        return nil;
    }
    errorString = [NSString stringWithUTF8String:errorBuffer];
    free(errorBuffer);
    return errorString;
}

@end
