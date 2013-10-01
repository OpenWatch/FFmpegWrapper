//
//  FFStream.h
//  LiveStreamer
//
//  Created by Christopher Ballinger on 10/1/13.
//  Copyright (c) 2013 OpenWatch, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "libavformat/avformat.h"

@class FFFile, FFInputStream, FFOutputStream;

@interface FFStream : NSObject
@property (nonatomic, weak) FFFile *parentFile;
@property (nonatomic) AVStream *stream;

- (id) initWithFile:(FFFile*)parentFile;
- (NSString*) codecName;

@end
