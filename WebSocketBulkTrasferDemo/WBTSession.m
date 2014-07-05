//
//  WVTSession.m
//  WebViewVideoTransfer_iOS
//
//  Created by Taiju Muto on 6/14/14.
//  Copyright (c) 2014 Taiju MUto. All rights reserved.
//

#import "WBTSession.h"
#include <sys/socket.h>
#include <CommonCrypto/CommonDigest.h>

#define PAYLOAD_LEN (1024 * 1024)
#define SEND_BUFFER_SIZE (1024 * 1024)
#define WRITE_BUFFER_LIMIT (1024 * 1024 * 10)

//#define ENABLE_LOG

#ifdef ENABLE_LOG
#define DEBUG_LOG(...) NSLog(__VA_ARGS__)
#else
#define DEBUG_LOG(...)
#endif

#define MAGIC_STRING @"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

@interface WBTSession ()<NSStreamDelegate>

@property (assign, nonatomic) CFSocketNativeHandle socket;
@property (retain, nonatomic) NSInputStream *inputStream;
@property (retain, nonatomic) NSOutputStream *outputStream;
@property (retain, nonatomic) NSMutableData *receiveBuffer;
@property (retain, nonatomic) NSMutableData *lineBuffer;
@property (assign, nonatomic) int linePos;
@property (retain, nonatomic) NSMutableArray *writeBuffers;
@property (assign, nonatomic) NSInteger writeBufferUsed;
@property (assign, nonatomic) NSInteger writePos;
@property (assign, nonatomic) BOOL doClose;
@property (assign, nonatomic) BOOL requestLineReceived;
@property (retain, nonatomic) NSString *webSocketKey;
@property (retain, nonatomic) NSString *path;
@property (assign, nonatomic) BOOL isWebSocket;
@property (assign, nonatomic) BOOL isHandshakeCompelete;

@end

@implementation WBTSession

- (instancetype)initWithSocket:(CFSocketNativeHandle)socket
{
    CFReadStreamRef readStreamRef;
    CFWriteStreamRef writeStreamRef;
    CFStreamCreatePairWithSocket(NULL, socket, &readStreamRef, &writeStreamRef);
    if (!readStreamRef || !writeStreamRef) {
        return nil;
    }
    
    if (!CFReadStreamSetProperty(readStreamRef, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue) ||
        !CFWriteStreamSetProperty(writeStreamRef, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue)) {
        CFRelease(readStreamRef);
        CFRelease(writeStreamRef);
        return nil;
    }
    
    NSInputStream *inputStream = (__bridge_transfer NSInputStream *)readStreamRef;
    NSOutputStream *outputStream = (__bridge_transfer NSOutputStream *)writeStreamRef;
    
    WBTSession *session = [super init];
    if (!session) {
        return nil;
    }
    
    int bufsize = SEND_BUFFER_SIZE;
    socklen_t size = sizeof(bufsize);
    if (setsockopt(socket, SOL_SOCKET, SO_SNDBUF, &bufsize, size) == -1) {
        return nil;
    }
    
    session.socket = socket;
    session.receiveBuffer = [NSMutableData dataWithLength:RECV_BUFF_SIZE];
    session.lineBuffer = [NSMutableData dataWithLength:LINE_SIZE];
    session.linePos = 0;
    session.writeBuffers = [NSMutableArray array];
    session.writeBufferUsed = 0;
    session.writePos = 0;
    session.doClose = NO;

    session.inputStream = inputStream;
    session.inputStream.delegate = self;
    [session.inputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [session.inputStream open];
    
    session.outputStream = outputStream;
    session.outputStream.delegate = self;
    [session.outputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [session.outputStream open];
    
    session.requestLineReceived = NO;
    session.path = nil;
    session.isWebSocket = NO;
    session.isHandshakeCompelete = NO;
    session.webSocketKey = nil;
    
    return session;
}

- (void)closeInput
{
    DEBUG_LOG(@"closeInput");
    
    if (self.inputStream) {
        [self.inputStream close];
        [self.inputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
        self.inputStream = nil;
        
        if (!self.inputStream && !self.outputStream) {
            [NSObject cancelPreviousPerformRequestsWithTarget:self];
            if (self.delegate) {
                [self.delegate didCloseSession:self];
            }
        }
    }
}

- (void)closeOutput
{
    DEBUG_LOG(@"closeOutput");
    
    if (self.outputStream) {
        [self.outputStream close];
        [self.outputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
        self.outputStream = nil;
        
        if (!self.inputStream && !self.outputStream) {
            [NSObject cancelPreviousPerformRequestsWithTarget:self];
            if (self.delegate) {
                [self.delegate didCloseSession:self];
            }
        }
    }
}

- (void)close {
    [self closeInput];
    [self closeOutput];
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)streamEvent {
    if (streamEvent == NSStreamEventHasBytesAvailable) {
        DEBUG_LOG(@"NSStreamEventHasBytesAvailable");
        [self receive];
    } else if (streamEvent == NSStreamEventHasSpaceAvailable) {
        DEBUG_LOG(@"NSStreamEventHasSpaceAvailable");
        [self flush];
    } else if (streamEvent == NSStreamEventErrorOccurred) {
        DEBUG_LOG(@"NSStreamEventErrorOccurred");
        [self close];
    } else if (streamEvent == NSStreamEventEndEncountered) {
        DEBUG_LOG(@"NSStreamEventEndEncountered");
        if (stream == self.inputStream) {
            [self closeInput];
        } else if (stream == self.outputStream) {
            [self closeOutput];
        }
    }
}

- (void)receive
{
    while (self.inputStream.hasBytesAvailable) {
        NSInteger len = [self.inputStream read:self.receiveBuffer.mutableBytes maxLength:self.receiveBuffer.length];
        if (len > 0) {
            if (![self consume:len]) {
                [self close];
                break;
            }
        } else if (len < 0) {
            NSLog(@"read error. %@", self.inputStream.streamError.description);
            [self close];
            break;
        } else {
            break;
        }
    }
    [self flush];
}

- (BOOL)consume:(NSInteger)bytesReceived
{
    if (self.isWebSocket && self.isHandshakeCompelete) {
        return YES;
    }
    
    for (int i = 0; i < bytesReceived; i++) {
        char c = ((char *)self.receiveBuffer.bytes)[i];
        switch (c) {
            case '\r':
            {
                break;
            }
            case '\n':
            {
                if (0 < self.linePos) {
                    NSString *line = [[NSString alloc] initWithBytes:self.lineBuffer.bytes length:self.linePos encoding: NSASCIIStringEncoding];
                    [self dispatchLine:line];
                    self.linePos = 0;
                } else {
                    if (self.isWebSocket) {
                        [self sendWebSocketResponse];
                        [self fillBuffer];
                        self.isHandshakeCompelete = YES;
                    } else {
                        [self sendFileResponse];
                    }
                }
                break;
            }
            default:
            {
                if (self.linePos < LINE_MAX) {
                    ((char *)self.lineBuffer.mutableBytes)[self.linePos++] = c;
                } else {
                    return NO;
                }
            }
        }
    }
    
    return YES;
}

- (void)dispatchLine:(NSString *)line
{
    if (self.requestLineReceived) {
        NSError *error = NULL;
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\S+?):\\s*(\\S+)"
                                                                               options:0
                                                                                 error:&error];
        NSTextCheckingResult *result = [regex firstMatchInString:line options:0 range:NSMakeRange(0, [line length])];
        if (result) {
            NSString *key = [[line substringWithRange:[result rangeAtIndex:1]] lowercaseString];
            NSString *value = [line substringWithRange:[result rangeAtIndex:2]];
            DEBUG_LOG(@"%@: %@", key, value);
            if ([key isEqualToString:@"sec-websocket-key"]) {
                self.webSocketKey = value;
            } else if ([key isEqualToString:@"upgrade"] && [value isEqualToString:@"websocket"]) {
                self.isWebSocket = YES;
            }
        }
    } else {
        DEBUG_LOG(@"%@", line);
        NSArray *parts = [line componentsSeparatedByString:@" "];
        self.path = parts[1];
        self.requestLineReceived = YES;
    }
}

- (void)enqueueData:(NSData *)data
{
    [self.writeBuffers addObject:data];
    self.writeBufferUsed += data.length;
}

- (void)dequeueData
{
    NSData *data = self.writeBuffers.firstObject;
    [self.writeBuffers removeObjectAtIndex:0];
    self.writeBufferUsed -= data.length;
}

- (void)flush
{
    DEBUG_LOG(@"flush");
    
    if (!self.outputStream) {
        return;
    }
        
    NSData *data;
    while (self.outputStream.hasSpaceAvailable && (data = self.writeBuffers.firstObject)) {
        NSInteger len = [self.outputStream write:data.bytes maxLength:data.length - self.writePos];
        if (len > 0) {
            self.writePos += len;
            if (self.writePos == data.length) {
                [self dequeueData];
                self.writePos = 0;
            } else {
                break;
            }
        } else if (len < 0) {
            NSLog(@"write error. %@", self.outputStream.streamError.description);
            [self close];
            break;
        } else {
            break;
        }
    }
    
    if (self.writeBuffers.count == 0 && self.doClose) {
        [self close];
    }
}

- (void)sendFileResponse
{
    DEBUG_LOG(@"sendFileResponse");
    
    NSString *dir_path = [[NSBundle mainBundle] pathForResource:@"html" ofType:nil];
    NSString *file_path = [dir_path stringByAppendingPathComponent:self.path];
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:file_path]) {
        NSData *data = [NSData dataWithContentsOfFile:file_path];
        NSMutableString *response = [NSMutableString string];
        [response appendString:@"HTTP/1.1 200 OK\r\n"];
        [response appendString:@"Connection: close\r\n"];
        [response appendFormat:@"Content-Length: %lu\r\n", (unsigned long)data.length];
        [response appendString:@"\r\n"];
        [self enqueueData:[response dataUsingEncoding:NSASCIIStringEncoding]];
        [self enqueueData:data];
    } else {
        NSMutableString *response = [NSMutableString string];
        [response appendString:@"HTTP/1.1 404 Not Found\r\n"];
        [response appendString:@"Connection: close\r\n"];
        [response appendFormat:@"Content-Length: 0\r\n"];
        [response appendString:@"\r\n"];
        [self enqueueData:[response dataUsingEncoding:NSASCIIStringEncoding]];
    }
    self.doClose = YES;
}

- (void)sendWebSocketResponse
{
    DEBUG_LOG(@"sendWebSocketResponse");
    
    NSMutableString *response = [NSMutableString string];
    
    NSString *keyStr = [self.webSocketKey stringByAppendingString:MAGIC_STRING];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    NSData *stringBytes = [keyStr dataUsingEncoding: NSUTF8StringEncoding];
    if (!CC_SHA1([stringBytes bytes], (CC_LONG)[stringBytes length], digest)) {
        abort();
    }
    NSData *data = [NSData dataWithBytes:digest length:CC_SHA1_DIGEST_LENGTH];
    NSString *webSocketAccept = [data base64EncodedStringWithOptions:NSDataBase64EncodingEndLineWithLineFeed];
    
    [response appendString:@"HTTP/1.1 101 Switching Protocols\r\n"];
    [response appendString:@"Upgrade: websocket\r\n"];
    [response appendString:@"Connection: Upgrade\r\n"];
    [response appendString:[NSString stringWithFormat:@"Sec-WebSocket-Accept: %@\r\n", webSocketAccept]];
    [response appendString:@"Access-Control-Allow-Origin: http://localhost:8080\r\n"];
    [response appendString:@"\r\n"];

    [self enqueueData:[response dataUsingEncoding:NSASCIIStringEncoding]];
}

- (void)sendPacket
{    
    BOOL fin = YES;
    NSUInteger payloadLen = PAYLOAD_LEN;
    NSInteger opcode = 0x02; // binary
    NSInteger len1 = 127;
    BOOL mask = NO;
    NSMutableData *header = [NSMutableData dataWithLength:10];
    unsigned char *data = (unsigned char *)[header bytes];
    data[0] = (fin ? 0x80 : 0x00) | (opcode & 0x0f);
    data[1] = (mask ? 0x80 : 0x00) | (len1 & 0x7f);
    data[2] = 0;
    data[3] = 0;
    data[4] = 0;
    data[5] = 0;
    data[6] = (payloadLen>>24) & 0xFF;
    data[7] = (payloadLen>>16) & 0xFF;
    data[8] = (payloadLen>> 8) & 0xFF;
    data[9] = (payloadLen>> 0) & 0xFF;
    [self enqueueData:header];
    
    NSMutableData *payload = [NSMutableData dataWithLength:payloadLen];
    [self enqueueData:payload];
}

- (void)fillBuffer
{
    DEBUG_LOG(@"fillBuffer bufferUsed=%d", self.writeBufferUsed);
    
    while (WRITE_BUFFER_LIMIT > self.writeBufferUsed + 10 + PAYLOAD_LEN) {
        [self sendPacket];
    }
    
    [self flush];
    
    [self performSelector:@selector(fillBuffer) withObject:nil afterDelay:0.1];
}

@end
