//
//  FFInputStream.m
//  LiveStreamer
//
//  Created by Christopher Ballinger on 10/1/13.
//  Copyright (c) 2013 OpenWatch, Inc. All rights reserved.
//

#import "FFInputStream.h"
#import "FFInputFile.h"

#import "libavutil/timestamp.h"

@implementation FFInputStream
@synthesize nextDTS, DTS, nextPTS, PTS;

- (id) initWithInputFile:(FFInputFile*)newInputFile stream:(AVStream*)newStream {
    if (self = [super initWithFile:newInputFile]) {
        self.nextPTS = AV_NOPTS_VALUE;
        self.PTS = AV_NOPTS_VALUE;
        self.nextDTS = AV_NOPTS_VALUE;
        self.DTS = AV_NOPTS_VALUE;
        self.filterInRescaleDeltaLast = AV_NOPTS_VALUE;
        self.sawFirstTS = NO;
        self.wrapCorrectionDone = NO;
        self.stream = newStream;
    }
    return self;
}

@end