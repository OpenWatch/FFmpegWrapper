//
//  FFmpegWrapper.m
//  FFmpegWrapper
//
//  Created by Christopher Ballinger on 9/14/13.
//  Copyright (c) 2013 OpenWatch, Inc. All rights reserved.
//
//  This file is part of FFmpegWrapper.
//
//  FFmpegWrapper is free software; you can redistribute it and/or
//  modify it under the terms of the GNU Lesser General Public
//  License as published by the Free Software Foundation; either
//  version 2.1 of the License, or (at your option) any later version.
//
//  FFmpegWrapper is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  Lesser General Public License for more details.
//
//  You should have received a copy of the GNU Lesser General Public
//  License along with FFmpegWrapper; if not, write to the Free Software
//  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
//

#import "FFmpegWrapper.h"
#import "avformat.h"

NSString const *kFFmpegInputFormatKey = @"kFFmpegInputFormatKey";
NSString const *kFFmpegOutputFormatKey = @"kFFmpegOutputFormatKey";
static NSString * const kFFmpegErrorDomain = @"org.ffmpeg.FFmpeg";
static NSString * const kFFmpegErrorCode = @"kFFmpegErrorCode";


@implementation FFmpegWrapper
@synthesize conversionQueue, callbackQueue;

- (void) dealloc {
    avformat_network_deinit();
}

- (id) init {
    if (self = [super init]) {
        self.conversionQueue = dispatch_queue_create("ffmpeg conversion queue", NULL);
        self.callbackQueue = dispatch_get_main_queue();
        av_register_all();
        avformat_network_init();
    }
    return self;
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

+ (NSError*) errorWithCode:(int)errorCode localizedDescription:(NSString*)description {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithCapacity:1];
    if (description) {
        [userInfo setObject:description forKey:NSLocalizedDescriptionKey];
    }
    [userInfo setObject:@(errorCode) forKey:kFFmpegErrorCode];
    return [NSError errorWithDomain:kFFmpegErrorDomain code:errorCode userInfo:userInfo];
}

+ (NSError*) errorForAVErrorNumber:(int)errorNumber {
    NSString *description = [self stringForAVErrorNumber:errorNumber];
    return [self errorWithCode:errorNumber localizedDescription:description];
}

+ (void) handleBadReturnValue:(int)returnValue completionBlock:(FFmpegWrapperCompletionBlock)completionBlock queue:(dispatch_queue_t)queue {
    if (completionBlock) {
        NSError *error = [[self class] errorForAVErrorNumber:returnValue];
        dispatch_async(queue, ^{
            completionBlock(NO, error);
        });
    }
}

- (void) convertInputPath:(NSString*)inputPath outputPath:(NSString*)outputPath options:(NSDictionary*)options progressBlock:(FFmpegWrapperProgressBlock)progressBlock completionBlock:(FFmpegWrapperCompletionBlock)completionBlock {
    dispatch_async(conversionQueue, ^{
        BOOL success = NO;
        NSError *error = nil;
        
        // You can override the detected input format
        AVInputFormat *inputFormat = NULL;
        AVDictionary *inputOptions = NULL;
        AVFormatContext *inputFormatContext = NULL;

        NSString *inputFormatString = [options objectForKey:kFFmpegInputFormatKey];
        if (inputFormatString) {
            inputFormat = av_find_input_format([inputFormatString UTF8String]);
        }
        
        // It's possible to send more options to the parser
        // av_dict_set(&inputOptions, "video_size", "640x480", 0);
        // av_dict_set(&inputOptions, "pixel_format", "rgb24", 0);
        // av_dict_free(&inputOptions); // Don't forget to free
        
        
        int openInputValue = avformat_open_input(&inputFormatContext, [inputPath UTF8String], inputFormat, &inputOptions);
        if (openInputValue != 0) {
            avformat_close_input(&inputFormatContext);
            [[self class] handleBadReturnValue:openInputValue completionBlock:completionBlock queue:callbackQueue];
            return;
        }
        
        // Open output format context
        AVFormatContext *outputFormatContext = NULL;
        NSString *outputFormatString = [options objectForKey:kFFmpegOutputFormatKey];
        
        int openOutputValue = avformat_alloc_output_context2(&outputFormatContext, NULL, [outputFormatString UTF8String], [outputPath UTF8String]);
        if (openOutputValue < 0) {
            avformat_close_input(&inputFormatContext);
            avformat_free_context(outputFormatContext);
            [[self class] handleBadReturnValue:openInputValue completionBlock:completionBlock queue:callbackQueue];
            return;
        }
        
        // Read the input file
        BOOL continueReading = YES;
        AVPacket packet;
        int frameReadValue = -1;
        while (continueReading) {
            frameReadValue = av_read_frame(inputFormatContext, &packet);
            if (frameReadValue != 0) {
                continueReading = NO;
            }
            
            if (progressBlock) {
                dispatch_async(callbackQueue, ^{
                    progressBlock(packet.pos / 1.0);
                });
            }
            av_free_packet(&packet);
        }
        if (frameReadValue < 0 && frameReadValue != AVERROR_EOF) {
            avformat_close_input(&inputFormatContext);
            avformat_free_context(outputFormatContext);
            [[self class] handleBadReturnValue:frameReadValue completionBlock:completionBlock queue:callbackQueue];
            return;
        }
        
        
        // Yay looks good!
        avformat_close_input(&inputFormatContext);
        avformat_free_context(outputFormatContext);
        success = YES;
        error = nil;
        if (completionBlock) {
            dispatch_async(callbackQueue, ^{
                completionBlock(success, error);
            });
        }
    });
}

@end
