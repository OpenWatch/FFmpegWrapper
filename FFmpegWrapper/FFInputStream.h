//
//  FFInputStream.h
//  LiveStreamer
//
//  Created by Christopher Ballinger on 10/1/13.
//  Copyright (c) 2013 OpenWatch, Inc. All rights reserved.
//

#import "FFStream.h"

@class FFInputFile;

@interface FFInputStream : FFStream
/* predicted dts of the next packet read for this stream or (when there are
 * several frames in a packet) of the next frame in current packet (in AV_TIME_BASE units) */
@property (nonatomic) int64_t       nextDTS;
@property (nonatomic) int64_t       DTS;       ///< dts of the last packet read for this stream (in AV_TIME_BASE units)

@property (nonatomic) int64_t       nextPTS;  ///< synthetic pts for the next decode frame (in AV_TIME_BASE units)
@property (nonatomic) int64_t       PTS;       ///< current pts of the decoded frame  (in AV_TIME_BASE units)
@property (nonatomic) int64_t filterInRescaleDeltaLast;

@property (nonatomic) BOOL sawFirstTS;
@property (nonatomic) BOOL wrapCorrectionDone;
@property (nonatomic) double timestampScale;

- (id) initWithInputFile:(FFInputFile*)newInputFile stream:(AVStream*)newStream;
@end
