//
//  FFInputFile.h
//  LiveStreamer
//
//  Created by Christopher Ballinger on 10/1/13.
//  Copyright (c) 2013 OpenWatch, Inc. All rights reserved.
//

#import "FFFile.h"

@interface FFInputFile : FFFile
@property (nonatomic) BOOL endOfFileReached;
@property (nonatomic) int64_t timestampOffset;
@property (nonatomic) int64_t lastTimestamp;

// True if more, false if EOF reached
- (BOOL) readFrameIntoPacket:(AVPacket*)packet error:(NSError**)error;

@end