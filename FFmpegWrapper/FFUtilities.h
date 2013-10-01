//
//  FFUtilities.h
//  LiveStreamer
//
//  Created by Christopher Ballinger on 10/1/13.
//  Copyright (c) 2013 OpenWatch, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface FFUtilities : NSObject

+ (NSError*) errorForAVError:(int)avErrorNumber;

@end
