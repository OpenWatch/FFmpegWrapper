//
//  FFStream.m
//  LiveStreamer
//
//  Created by Christopher Ballinger on 10/1/13.
//  Copyright (c) 2013 OpenWatch, Inc. All rights reserved.
//

#import "FFStream.h"


@implementation FFStream
@synthesize stream, parentFile;
- (id) initWithFile:(FFFile *)newParentFile {
    if (self = [super init]) {
        self.parentFile = newParentFile;
    }
    return self;
}

- (NSString*) codecName {
    if (!stream) {
        return nil;
    }
    AVCodecContext *inputCodecContext = stream->codec;
    const char *codec_name = avcodec_get_name(inputCodecContext->codec_id);
    return [NSString stringWithUTF8String:codec_name];
}

@end